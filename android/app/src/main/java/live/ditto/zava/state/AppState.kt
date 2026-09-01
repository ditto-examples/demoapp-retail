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

    private var storesObserver: DittoStoreObserver? = null

    companion object {
        private const val TAG = "AppState"
        const val KEY_SELECTED_STORE = "selectedStoreId"
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
