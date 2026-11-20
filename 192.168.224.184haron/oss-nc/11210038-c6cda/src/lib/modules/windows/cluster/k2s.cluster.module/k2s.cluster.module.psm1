# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# USAGE NOTES
# Root module of k2s.core.module which contains all the sub-modules and functions needed for core functionalities.
# Import-Module k2s.core.module

Get-ChildItem -Path "$PSScriptRoot" -Filter '*.psm1' -Recurse | Where-Object { $_.FullName -ne "$PSCommandPath" } | Foreach-Object { Import-Module $_.FullName }
# DO NOT USE -FORCE, INSTEAD MODIFY THE FUNCTION WITH APPROVED VERBS https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands?view=powershell-5.1

# For debugging
#Export-ModuleMember -Function '*' -Variable '*'
