#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for the helpers defined in run-issue-agent-phases.ps1. We extract
# function definitions via AST so the tests run against the live source.

BeforeAll {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Import-Module (Join-Path $PSScriptRoot 'Helpers.psm1') -Force

    $scriptPath = Join-Path $PSScriptRoot '..' 'run-issue-agent-phases.ps1'
    $source = Import-ScriptFunctions -ScriptPath $scriptPath -FunctionNames @(
        'Get-PropertyValue', 'Set-PropertyValue', 'ConvertTo-Array',
        'Get-TextBlob', 'Test-TextMentionsUnavailableEvidence',
        'Test-TextMentionsFailedTests', 'Get-ToolFailureCategory'
    )
    . ([scriptblock]::Create($source))
}

Describe 'ConvertTo-Array' {
    # PS's function-return-unwrap means callers MUST use one of two safe patterns:
    #   (a) assign + wrap:    $x = @(ConvertTo-Array $y)    then $x.Count is safe
    #   (b) pipe:             ConvertTo-Array $y | Where-Object { ... }  iterates per element
    # An earlier `return ,@(...)` variant was correct for (a) but broke (b) — the
    # comma-preserved outer array landed as a single $_ in pipeline filters.
    It 'with @() wrap returns a real array for null/scalar/array inputs' {
        $a = @(ConvertTo-Array -Value $null)
        ($a -is [array]) | Should -BeTrue
        $a.Count         | Should -Be 0

        $b = @(ConvertTo-Array -Value 'lonely')
        ($b -is [array]) | Should -BeTrue
        $b.Count         | Should -Be 1
        $b[0]            | Should -Be 'lonely'

        $c = @(ConvertTo-Array -Value @(1, 2, 3))
        ($c -is [array]) | Should -BeTrue
        $c.Count         | Should -Be 3
    }
    It 'when piped through Where-Object, iterates per element (pipe-form regression guard)' {
        $entries = @(
            [pscustomobject]@{ field = 'deck'; input = 'BASH'  },
            [pscustomobject]@{ field = 'deck'; input = 'ANGER' }
        )
        $matches = ConvertTo-Array $entries | Where-Object { $_.input -eq 'BASH' }
        @($matches).Count | Should -Be 1
        @($matches)[0].input | Should -Be 'BASH'
    }
    It 'when piped from null input, emits no items' {
        $matches = ConvertTo-Array $null | Where-Object { $true }
        @($matches).Count | Should -Be 0
    }
    It 'when piped from a single scalar, iterates one element' {
        $matches = ConvertTo-Array 'BASH' | Where-Object { $_ -eq 'BASH' }
        @($matches).Count | Should -Be 1
    }
}

Describe 'Get-PropertyValue / Set-PropertyValue (IDictionary + PSCustomObject)' {
    It 'reads / writes on an [ordered] dict' {
        $d = [ordered]@{ status = 'pass' }
        Get-PropertyValue -Object $d -Name 'status' | Should -Be 'pass'
        Set-PropertyValue -Object $d -Name 'status' -Value 'abort'
        Set-PropertyValue -Object $d -Name 'new'    -Value 7
        $d['status'] | Should -Be 'abort'
        $d['new']    | Should -Be 7
    }
    It 'reads / writes on a PSCustomObject' {
        $o = [pscustomobject]@{ status = 'pass' }
        Get-PropertyValue -Object $o -Name 'status' | Should -Be 'pass'
        Set-PropertyValue -Object $o -Name 'status' -Value 'abort'
        Set-PropertyValue -Object $o -Name 'new'    -Value 7
        $o.status | Should -Be 'abort'
        $o.new    | Should -Be 7
    }
    It 'returns null for missing keys / does nothing on null receivers' {
        Get-PropertyValue -Object $null -Name 'foo' | Should -BeNullOrEmpty
        $d = [ordered]@{ a = 1 }
        Get-PropertyValue -Object $d -Name 'missing' | Should -BeNullOrEmpty
        Set-PropertyValue -Object $null -Name 'foo' -Value 1   # should not throw
    }
}

Describe 'Get-TextBlob' {
    It 'joins non-empty values with newlines, skipping null/whitespace' {
        Get-TextBlob -Values @('one', '', $null, '  ', 'two') | Should -Be "one`ntwo"
    }
    It 'returns empty when all values are null/whitespace' {
        Get-TextBlob -Values @($null, '', '   ') | Should -Be ''
    }
}

Describe 'Test-TextMentionsUnavailableEvidence' {
    It 'detects unavailable / not achievable phrasings' {
        Test-TextMentionsUnavailableEvidence -Text 'tooltip not achievable on this surface' | Should -BeTrue
        Test-TextMentionsUnavailableEvidence -Text 'verified exclusively through unit tests' | Should -BeTrue
        Test-TextMentionsUnavailableEvidence -Text 'cannot be made visible without mouse hover' | Should -BeTrue
    }
    It 'returns false on benign text' {
        Test-TextMentionsUnavailableEvidence -Text 'all evidence captured' | Should -BeFalse
        Test-TextMentionsUnavailableEvidence -Text $null | Should -BeFalse
        Test-TextMentionsUnavailableEvidence -Text ''    | Should -BeFalse
    }
}

Describe 'Test-TextMentionsFailedTests' {
    It 'detects failure phrasing' {
        Test-TextMentionsFailedTests -Text 'partial pass' | Should -BeTrue
        Test-TextMentionsFailedTests -Text '3 tests failed' | Should -BeTrue
        Test-TextMentionsFailedTests -Text '2 regressions in legacy/parser' | Should -BeTrue
    }
    It 'ignores benign mentions' {
        Test-TextMentionsFailedTests -Text 'all green' | Should -BeFalse
        Test-TextMentionsFailedTests -Text $null      | Should -BeFalse
        Test-TextMentionsFailedTests -Text ''         | Should -BeFalse
    }
}
