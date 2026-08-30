import React from 'react'
import { StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native'
import { useAnvilColors } from '../theme'

export interface AnvilCardProps {
  style?: StyleProp<ViewStyle>
  children: React.ReactNode
}

/** Surface container with Anvil's normal border and radius. */
export function AnvilCard({ style, children }: AnvilCardProps) {
  const colors = useAnvilColors()
  return (
    <View
      style={[
        styles.base,
        { backgroundColor: colors.surface, borderColor: colors.borderNormal },
        style,
      ]}
    >
      {children}
    </View>
  )
}

const styles = StyleSheet.create({
  base: { borderRadius: 12, borderWidth: 1, padding: 16 },
})
