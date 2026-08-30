import React from 'react'
import {
  StyleSheet,
  Text,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native'
import { useAnvilColors } from '../theme'
import type { AnvilSemanticColors } from '../semantic'

export type AnvilBadgeStatus = 'info' | 'success' | 'warning' | 'critical' | 'promo'

export interface AnvilBadgeProps {
  status?: AnvilBadgeStatus
  style?: StyleProp<ViewStyle>
  children: string
}

const fills: Record<AnvilBadgeStatus, (c: AnvilSemanticColors) => string> = {
  info: (c) => c.fillInfoSecondary,
  success: (c) => c.fillSuccessSecondary,
  warning: (c) => c.fillWarningSecondary,
  critical: (c) => c.fillCriticalSecondary,
  promo: (c) => c.fillPromoSecondary,
}

/** Small status pill using Anvil's secondary status fills (AA body text). */
export function AnvilBadge({ status = 'info', style, children }: AnvilBadgeProps) {
  const colors = useAnvilColors()
  return (
    <View style={[styles.base, { backgroundColor: fills[status](colors) }, style]}>
      <Text style={[styles.label, { color: colors.foregroundNormal }]}>
        {children}
      </Text>
    </View>
  )
}

const styles = StyleSheet.create({
  base: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 2,
    alignSelf: 'flex-start',
  },
  label: { fontSize: 12, lineHeight: 16, fontWeight: '500' },
})
