import React from 'react'
import {
  StyleSheet,
  Text,
  TextInput,
  View,
  type StyleProp,
  type TextInputProps,
  type ViewStyle,
} from 'react-native'
import { useAnvilColors } from '../theme'
import { anvilFontFamily } from '../typography'

export interface AnvilInputProps extends TextInputProps {
  label?: string
  /** When true, border switches to the critical (error) color. */
  error?: boolean
  containerStyle?: StyleProp<ViewStyle>
}

/** Themed text input with optional label and error state. */
export function AnvilInput({
  label,
  error,
  containerStyle,
  style,
  ...rest
}: AnvilInputProps) {
  const colors = useAnvilColors()
  return (
    <View style={containerStyle}>
      {label != null && (
        <Text style={[styles.label, { color: colors.foregroundNormal, fontFamily: anvilFontFamily }]}>
          {label}
        </Text>
      )}
      <TextInput
        placeholderTextColor={colors.foregroundSubtle}
        style={[
          styles.input,
          {
            color: colors.foregroundNormal,
            backgroundColor: colors.surface,
            borderColor: error ? colors.borderCritical : colors.borderNormal,
            fontFamily: anvilFontFamily,
          },
          style,
        ]}
        {...rest}
      />
    </View>
  )
}

const styles = StyleSheet.create({
  label: { fontSize: 14, lineHeight: 20, fontWeight: '500', marginBottom: 6 },
  input: {
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 14,
    minHeight: 40,
  },
})
