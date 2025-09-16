# VM Name Sanitization Fix

## Problem
VM names containing special characters like `()[]{}` cause Zabbix errors:
```
Character "(" is not allowed
```

## Solution
The updated script now provides both original and sanitized VM names in discovery data.

## Updated Discovery Output
The script now returns additional `{#VMNAME_SAFE}` field:

```json
{
 "data":[
  { "{#VMNAME}":"SQL(Production)", "{#VMNAME_SAFE}":"SQL_Production_", "{#VMSTATE}":"Running", "{#VMHOST}":"HV01", "{#REPLICATION}":"Disabled" },
  { "{#VMNAME}":"Web[Test]", "{#VMNAME_SAFE}":"Web_Test_", "{#VMSTATE}":"Running", "{#VMHOST}":"HV01", "{#REPLICATION}":"Disabled" },
  { "{#VMNAME}":"App/Server", "{#VMNAME_SAFE}":"App_Server", "{#VMSTATE}":"Running", "{#VMHOST}":"HV01", "{#REPLICATION}":"Disabled" }
 ]
}
```

## Character Replacement Rules
The following characters are replaced with underscore `_`:
- Parentheses: `()` 
- Brackets: `[]` 
- Braces: `{}`
- Slashes: `\/`
- Special chars: `|?*"':;,=+&%@!#$^`~`

## Usage in Zabbix Templates
- Use `{#VMNAME}` for display names and human-readable references
- Use `{#VMNAME_SAFE}` for item keys and any technical identifiers
- The script automatically handles both original and sanitized names in performance counter queries

## Automatic Fallback
The script tries performance counter queries with both:
1. Original VM name (for backward compatibility)
2. Sanitized VM name (for problematic characters)

This ensures monitoring works regardless of VM naming conventions.