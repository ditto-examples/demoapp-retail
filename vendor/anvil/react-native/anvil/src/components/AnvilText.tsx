import React from 'react'
import { StyleSheet, Text, type StyleProp, type TextStyle } from 'react-native'
import { useAnvilColors } from '../theme'
import { anvilFontFamily, anvilMonoFontFamily } from '../typography'

export type AnvilTextVariant =
  | 'displayLarge'
  | 'headlineLarge'
  | 'headlineSmall'
  | 'titleLarge'
  | 'titleMedium'
  | 'bodyLarge'
  | 'bodyMedium'
  | 'bodySmall'
  | 'labelLarge'
  | 'labelMedium'
  | 'code'

const variantStyles = StyleSheet.create({
  displayLarge: { fontSize: 57, lineHeight: 64, fontWeight: '400' },
  headlineLarge: { fontSize: 32, lineHeight: 40, fontWeight: '400' },
  headlineSmall: { fontSize: 24, lineHeight: 32, fontWeight: '400' },
  titleLarge: { fontSize: 22, lineHeight: 28, fontWeight: '400' },
  titleMedium: { fontSize: 16, lineHeight: 24, fontWeight: '500' },
  bodyLarge: { fontSize: 16, lineHeight: 24, fontWeight: '400' },
  bodyMedium: { fontSize: 14, lineHeight: 20, fontWeight: '400' },
  bodySmall: { fontSize: 12, lineHeight: 16, fontWeight: '400' },
  labelLarge: { fontSize: 14, lineHeight: 20, fontWeight: '500' },
  labelMedium: { fontSize: 12, lineHeight: 16, fontWeight: '500' },
  code: { fontSize: 14, lineHeight: 20, fontWeight: '400' },
})

export interface AnvilTextProps {
  variant?: AnvilTextVariant
  /** Defaults to `foregroundNormal`. */
  color?: string
  style?: StyleProp<TextStyle>
  children: React.ReactNode
}

/** Themed text following the Anvil type scale (Inter; code uses IBM Plex Mono). */
export function AnvilText({
  variant = 'bodyMedium',
  color,
  style,
  children,
}: AnvilTextProps) {
  const colors = useAnvilColors()
  const fontFamily =
    variant === 'code' ? anvilMonoFontFamily : anvilFontFamily
  return (
    <Text
      style={[
        variantStyles[variant],
        { fontFamily, color: color ?? colors.foregroundNormal },
        style,
      ]}
    >
      {children}
    </Text>
  )
}
