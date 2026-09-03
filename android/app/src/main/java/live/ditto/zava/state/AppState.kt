package live.ditto.zava.state

import android.app.Application
import android.content.Context
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ditto.kotlin.Ditto
import com.ditto.kotlin.DittoLogLevel
import com.ditto.kotlin.DittoLogger
import com.ditto.kotlin.DittoStoreObserver
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import live.ditto.zava.BuildConfig
import live.ditto.zava.data.DatabaseConfig
import live.ditto.zava.data.DittoManager
import live.ditto.zava.model.MulticastConfig
import live.ditto.zava.model.Store

/// App-level state (1:1 port of the Swift reference's @MainActor AppState).
/// All mutations happen on the main thread (viewModelScope / coalesced
/// observer delivery).
class AppState(application: Application) : AndroidViewModel(application) {

    sealed interface Boot {
        data object Loading : Boot
        data object MissingConfig : Boot
        data object Ready : Boot
        data class Failed(val message: String) : Boot
    }

    private val prefs = application.getSharedPreferences("zava", Context.MODE_PRIVATE)

    private val _boot = MutableStateFlow<Boot>(Boot.Loading)
    val boot: StateFlow<Boot> = _boot.asStateFlow()

    private val _stores = MutableStateFlow<List<Store>>(emptyList())
    val stores: StateFlow<List<Store>> = _stores.asStateFlow()

    private val _selectedStoreId = MutableStateFlow(prefs.getString(KEY_SELECTED_STORE, null))
    val selectedStoreId: StateFlow<String?> = _selectedStoreId.asStateFlow()

    /// The one global error surface — the banner at the top of the root.
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _ditto = MutableStateFlow<Ditto?>(null)
    val ditto: StateFlow<Ditto?> = _ditto.asStateFlow()

    /// The multicast (beta) transport settings — persisted, applied to Ditto
    /// after open and on every change.
    private val _multicastConfig = MutableStateFlow(loadMulticastConfig())
    val multicastConfig: StateFlow<MulticastConfig> = _multicastConfig.asStateFlow()

    private var storesObserver: DittoStoreObserver? = null

    companion object {
        private const val TAG = "AppState"
        const val KEY_SELECTED_STORE = "selectedStoreId"
        private const val KEY_MULTICAST_ENABLED = "multicastEnabled"
        private const val KEY_MULTICAST_GROUP = "multicastGroupAddress"
        private const val KEY_MULTICAST_PORT = "multicastPort"
        private const val KEY_MULTICAST_INTERFACE = "multicastInterfaceName"
    }

    private fun loadMulticastConfig(): MulticastConfig = MulticastConfig(
        enabled = prefs.getBoolean(KEY_MULTICAST_ENABLED, false),
        groupAddress = prefs.getString(KEY_MULTICAST_GROUP, null) ?: MulticastConfig.DEFAULT_GROUP_ADDRESS,
        port = prefs.getInt(KEY_MULTICAST_PORT, MulticastConfig.DEFAULT_PORT),
        interfaceName = prefs.getString(KEY_MULTICAST_INTERFACE, null)?.ifEmpty { null },
    )

    /// Persists + applies multicast settings to the live Ditto instance.
    /// The SDK defers multicast changes while sync is active on Android, so
    /// applying live costs a brief sync stop→apply→start (in DittoManager).
    /// Validation failures surface in the banner, never crash.
    fun setMulticastConfig(config: MulticastConfig) {
        prefs.edit()
            .putBoolean(KEY_MULTICAST_ENABLED, config.enabled)
            .putString(KEY_MULTICAST_GROUP, config.groupAddress)
            .putInt(KEY_MULTICAST_PORT, config.port)
            .putString(KEY_MULTICAST_INTERFACE, config.interfaceName)
            .apply()
        _multicastConfig.value = config
        viewModelScope.launch {
            try {
                DittoManager.setMulticastConfig(config)
            } catch (e: Exception) {
                _lastError.value = "Multicast config failed: ${e.localizedMessage}"
            }
        }
    }

    init {
        DittoManager.init(application)
    }

    override fun onCleared() {
        storesObserver?.close()
        storesObserver = null
    }

    private fun persistSelection(storeId: String?) {
        if (storeId != null) {
            prefs.edit().putString(KEY_SELECTED_STORE, storeId).apply()
        } else {
            prefs.edit().remove(KEY_SELECTED_STORE).apply()
        }
    }

    fun bootApp() {
        if (_boot.value != Boot.Loading) return
        val config = DatabaseConfig.load()
        if (config == null) {
            _boot.value = Boot.MissingConfig
            return
        }
        if (BuildConfig.DEBUG) {
            DittoLogger.minimumLogLevel = DittoLogLevel.Debug
        }
        viewModelScope.launch {
            try {
                // Stage the persisted multicast (beta) config BEFORE open:
                // the SDK defers multicast changes while sync is active, so
                // open() applies it pre-sync-start (no stop/start churn).
                DittoManager.pendingMulticastConfig = _multicastConfig.value
                val instance = DittoManager.open(config) { message ->
                    viewModelScope.launch { _lastError.value = message }
                }
                _ditto.value = instance
                Log.i(TAG, "Ditto open; sync started")
                storesObserver = DittoManager.observe<Store>("SELECT * FROM stores") { stores ->
                    Log.i(TAG, "stores observer fired: ${stores.size} stores")
                    _stores.value = stores.sortedBy { it.store_name }
                }
                _selectedStoreId.value?.let { persisted ->
                    if (DittoManager.isValidStoreId(persisted)) {
                        Log.i(TAG, "applying persisted store selection: $persisted")
                        DittoManager.applyStoreSelection(persisted)
                    } else {
                        // Corrupt/stale pref — drop it and land on the
                        // picker, never on a recovery-less Failed screen.
                        Log.w(TAG, "persisted store id '$persisted' is invalid — clearing")
                        _selectedStoreId.value = null
                        prefs.edit().remove(KEY_SELECTED_STORE).apply()
                    }
                }
                _boot.value = Boot.Ready
            } catch (e: Exception) {
                Log.e(TAG, "boot failed: ${e.localizedMessage}")
                _boot.value = Boot.Failed(e.localizedMessage ?: "unknown error")
            }
        }
    }

    fun selectStore(storeId: String) {
        _selectedStoreId.value = storeId
        persistSelection(storeId)
        viewModelScope.launch {
            try {
                DittoManager.applyStoreSelection(storeId)
            } catch (e: Exception) {
                _lastError.value = "Store switch failed: ${e.localizedMessage}"
                // Roll the UI back to whatever the manager actually serves.
                _selectedStoreId.value = DittoManager.currentStoreId
                persistSelection(DittoManager.currentStoreId)
            }
        }
    }

    /// Returns to the store picker. The current store keeps syncing until a
    /// new selection replaces it (per-store subscriptions stay live).
    fun switchStore() {
        _selectedStoreId.value = null
        persistSelection(null)
    }

    fun dismissError() {
        _lastError.value = null
    }

    /// Boot is retryable: a transient failure (network, auth) must not brick
    /// the app. The Failed screen's Retry button calls this.
    fun retryBoot() {
        if (_boot.value is Boot.Failed) {
            _boot.value = Boot.Loading
            bootApp()
        }
    }
}
