#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for the expected_text enforcement in Apply-VerificationEvidenceGuard.
# The guard is too entangled with the surrounding script (closure over $IssueNumber,
# $ValidationArtifactDir, etc.) to dot-source standalone, so these tests exercise
# the comparison logic directly with a tiny re-implementation that mirrors the
# production check at run-issue-agent-phases.ps1 (Apply-VerificationEvidenceGuard's
# expected_text branch). If the production check changes, this re-implementation
# must change in lockstep.

BeforeAll {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    function Test-ExpectedTextMatch {
        param([string]$ExpectedText, [string]$ObservedText)
        if ([string]::IsNullOrWhiteSpace($ExpectedText)) { return $true }
        $needle = $ExpectedText.Trim()
        $haystack = ([string]$ObservedText).Trim()
        $pattern = '(?:^|[^A-Za-z0-9])' + [regex]::Escape($needle) + '(?:[^A-Za-z0-9]|$)'
        return [regex]::IsMatch($haystack, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
}

Describe 'expected_text enforcement (mirrors Apply-VerificationEvidenceGuard)' {
    It 'passes when observed contains expected (case-insensitive)' {
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText 'Akabeko vigor gained: 8' | Should -BeTrue
        Test-ExpectedTextMatch -ExpectedText 'Vigor Gained: 8' -ObservedText 'akabeko vigor gained: 8' | Should -BeTrue
    }
    It 'fails when observed contains a different number — the PR #170 failure mode' {
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText 'Akabeko vigor gained: 88' | Should -BeFalse
    }
    It 'fails when observed is missing the expected text entirely' {
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText 'Akabeko tooltip rendered' | Should -BeFalse
    }
    It 'fails when observed is empty' {
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText '' | Should -BeFalse
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText $null | Should -BeFalse
    }
    It 'is a no-op when expected_text is empty / unset' {
        Test-ExpectedTextMatch -ExpectedText '' -ObservedText 'whatever' | Should -BeTrue
        Test-ExpectedTextMatch -ExpectedText '   ' -ObservedText 'whatever' | Should -BeTrue
    }
    It 'tolerates surrounding whitespace' {
        Test-ExpectedTextMatch -ExpectedText '  vigor gained: 8  ' -ObservedText '...vigor gained: 8...' | Should -BeTrue
    }
    It 'rejects digit-prefix matches (PR #170: 8 must not match 88)' {
        # Same pattern at the longer end of the value.
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText 'vigor gained: 80' | Should -BeFalse
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText 'vigor gained: 800' | Should -BeFalse
    }
    It 'matches when the needle is the whole observed string' {
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText 'vigor gained: 8' | Should -BeTrue
    }
    It 'matches at the start of observed text' {
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText 'vigor gained: 8 in tooltip' | Should -BeTrue
    }
    It 'matches at the end of observed text' {
        Test-ExpectedTextMatch -ExpectedText 'vigor gained: 8' -ObservedText 'tooltip says vigor gained: 8' | Should -BeTrue
    }
}
