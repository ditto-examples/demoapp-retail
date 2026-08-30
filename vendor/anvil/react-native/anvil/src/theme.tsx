import React, { createContext, useContext, useMemo } from 'react'
import { useColorScheme } from 'react-native'
import {
  anvilSemanticColors,
  type AnvilSemanticColors,
} from './semantic'

/** Which Ditto theme the app should resolve to. */
export type AnvilThemeMode = 'system' | 'light' | 'dark'

export interface AnvilTheme {
  colors: AnvilSemanticColors
  dark: boolean
}

const defaultTheme: AnvilTheme = { colors: anvilSemanticColors('light'), dark: false }

const AnvilThemeContext = createContext<AnvilTheme>(defaultTheme)

export interface AnvilThemeProviderProps {
  /** Light, dark, or follow-system (default). */
  mode?: AnvilThemeMode
  children: React.ReactNode
}

/**
 * Ditto brand theme for React Native apps.
 *
 * Wrap the app root:
 *
 * ```tsx
 * <AnvilThemeProvider>
 *   <App /> // hooks below now resolve Ditto colors
 * </AnvilThemeProvider>
 * ```
 */
export function AnvilThemeProvider({
  mode = 'system',
  children,
}: AnvilThemeProviderProps) {
  const systemScheme = useColorScheme()
  const dark = mode === 'dark' || (mode === 'system' && systemScheme === 'dark')
  const value = useMemo<AnvilTheme>(
    () => ({ colors: anvilSemanticColors(dark ? 'dark' : 'light'), dark }),
    [dark],
  )
  return (
    <AnvilThemeContext.Provider value={value}>
      {children}
    </AnvilThemeContext.Provider>
  )
}

/**
 * Anvil's semantic colors for the active theme — fills, foregrounds, borders,
 * status and code colors. Falls back to light outside a provider.
 *
 * ```tsx
 * const colors = useAnvilColors()
 * <Text style={{ color: colors.fillSuccess }}>Everything is synced</Text>
 * ```
 */
export function useAnvilColors(): AnvilSemanticColors {
  return useContext(AnvilThemeContext).colors
}

/** True when the active tier is dark. */
export function useAnvilDark(): boolean {
  return useContext(AnvilThemeContext).dark
}
