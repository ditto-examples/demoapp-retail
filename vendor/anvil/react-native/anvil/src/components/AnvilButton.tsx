import React from 'react'
import {
  Pressable,
  StyleSheet,
  Text,
  type PressableProps,
  type StyleProp,
  type ViewStyle,
} from 'react-native'
import { useAnvilColors } from '../theme'
import { anvilFontFamily } from '../typography'

export type AnvilButtonVariant = 'primary' | 'secondary' | 'ghost'
export type AnvilButtonSize = 'md' | 'sm'

export interface AnvilButtonProps extends Omit<PressableProps, 'style' | 'children'> {
  variant?: AnvilButtonVariant
  size?: AnvilButtonSize
  style?: StyleProp<ViewStyle>
  children: string
}

/**
 * Anvil button on a core `Pressable`.
 * - `primary` (default): brand fill — black/white in light tier,
 *   black-on-citrus in dark tier (Ditto's signature).
 * - `secondary`: neutral container.
 * - `ghost`: transparent, accent-colored label.
 */
export function AnvilButton({
  variant = 'primary',
  size = 'md',
  disabled,
  style,
  children,
  ...rest
}: AnvilButtonProps) {
  const colors = useAnvilColors()

  const bg = disabled
    ? colors.fillDisabled
    : variant === 'primary'
      ? colors.fillBrandPrimary
      : variant === 'secondary'
        ? colors.surfaceSecondary
        : 'transparent'
  const fg = disabled
    ? colors.foregroundDisabled
    : variant === 'primary'
      ? colors.foregroundOnBrandPrimary
      : variant === 'secondary'
        ? colors.foregroundNormal
        : colors.foregroundAccent

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled: !!disabled }}
      disabled={disabled}
      style={({ pressed }) => [
        styles.base,
        size === 'sm' ? styles.sm : styles.md,
        { backgroundColor: bg },
        variant === 'ghost' && styles.ghostBorder,
        pressed && !disabled && { opacity: 0.85 },
        typeof style === 'function' ? undefined : style,
      ]}
      {...rest}
    >
      <Text
        style={[
          styles.label,
          size === 'sm' && styles.labelSm,
          { color: fg, fontFamily: anvilFontFamily },
        ]}
      >
        {children}
      </Text>
    </Pressable>
  )
}

const styles = StyleSheet.create({
  base: {
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
    alignSelf: 'flex-start',
  },
  md: { paddingHorizontal: 16, paddingVertical: 10, minHeight: 40 },
  sm: { paddingHorizontal: 12, paddingVertical: 6, minHeight: 32 },
  ghostBorder: { borderWidth: 1, borderColor: 'transparent' },
  label: { fontSize: 14, lineHeight: 20, fontWeight: '500' },
  labelSm: { fontSize: 12, lineHeight: 16 },
})
