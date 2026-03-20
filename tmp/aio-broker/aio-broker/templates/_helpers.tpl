// This helper function takes an array with objects of 'name' key as input and value of type string and then iterates over all
// entries and builds a single string with values concantenated together but separated by comma as output
{{- define "extractImageValuesToString" -}}
{{- $values := .values -}}
{{- $stringValue := "" -}}
{{- range $index, $value := $values }}
{{- $stringValue = print $stringValue $value.name -}}
{{- if ne (add $index 1) (len $values) }}{{ $stringValue = print $stringValue "," }}{{ end }}
{{- end }}
{{- if $stringValue }}
{{- $trimmedValue := trimPrefix "\n" $stringValue -}}
{{- $trimmedValue }}
{{- end }}
{{- end }}
