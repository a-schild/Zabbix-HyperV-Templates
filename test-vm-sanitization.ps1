# Test script to validate VM name sanitization functionality
# This script tests the sanitization function without requiring actual VMs

# Source the main script functions
. ".\zabbix-vm-perf.ps1"

Write-Host "Testing VM Name Sanitization Function" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green

# Test cases with problematic VM names
$testCases = @(
    @{ Original = "SQL(Production)"; Expected = "SQL_Production_" },
    @{ Original = "Web[Test]"; Expected = "Web_Test_" },
    @{ Original = "App/Server"; Expected = "App_Server" },
    @{ Original = "DB{Main}"; Expected = "DB_Main_" },
    @{ Original = "File\Share"; Expected = "File_Share" },
    @{ Original = "Mail|Exchange"; Expected = "Mail_Exchange" },
    @{ Original = "Test?VM"; Expected = "Test_VM" },
    @{ Original = "VM*Backup"; Expected = "VM_Backup" },
    @{ Original = "App ""Production"""; Expected = "App__Production__" },
    @{ Original = "VM:Special"; Expected = "VM_Special" },
    @{ Original = "Normal-VM"; Expected = "Normal-VM" },
    @{ Original = "Simple"; Expected = "Simple" }
)

$passed = 0
$failed = 0

foreach ($test in $testCases) {
    $result = Sanitize-VMName $test.Original
    if ($result -eq $test.Expected) {
        Write-Host "✓ PASS: '$($test.Original)' → '$result'" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "✗ FAIL: '$($test.Original)' → '$result' (expected: '$($test.Expected)')" -ForegroundColor Red
        $failed++
    }
}

Write-Host "`nTest Results:" -ForegroundColor Yellow
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor Red

if ($failed -eq 0) {
    Write-Host "`n✓ All tests passed! VM name sanitization is working correctly." -ForegroundColor Green
} else {
    Write-Host "`n✗ Some tests failed. Please review the sanitization function." -ForegroundColor Red
}

# Test discovery output format
Write-Host "`nTesting Discovery Output Format:" -ForegroundColor Yellow
Write-Host "=================================" -ForegroundColor Yellow

# Mock VM data for testing
$mockVMs = @(
    @{ Name = "SQL(Production)"; State = "Running"; ReplicationState = "Disabled" },
    @{ Name = "Web[Test]"; State = "Running"; ReplicationState = "Disabled" },
    @{ Name = "Normal-VM"; State = "Off"; ReplicationState = "Suspended" }
)

$mockHostname = "HV01"

Write-Host "Mock discovery output:"
Write-Host "{"
Write-Host " `"data`":["

$n = $mockVMs.Count
foreach ($vm in $mockVMs) {
    $originalName = $vm.Name
    $sanitizedName = Sanitize-VMName $originalName

    $line = " { `"{#VMNAME}`":`"$originalName`" ,`"{#VMNAME_SAFE}`":`"$sanitizedName`" ,`"{#VMSTATE}`":`"$($vm.State)`", `"{#VMHOST}`":`"$mockHostname`" ,`"{#REPLICATION}`":`"$($vm.ReplicationState)`" }"
    if ($n -gt 1) {
        $line += ","
    }
    Write-Host $line
    $n--
}

Write-Host " ]"
Write-Host "}"

Write-Host "`n✓ Discovery output format test completed." -ForegroundColor Green

# Test reverse mapping functionality
Write-Host "`nTesting Reverse Mapping Function:" -ForegroundColor Yellow
Write-Host "===================================" -ForegroundColor Yellow

# Mock the Get-VM cmdlet for testing
function Mock-Get-VM {
    return @(
        @{ Name = "SQL(Production)" },
        @{ Name = "Web[Test]" },
        @{ Name = "App/Server" },
        @{ Name = "Normal-VM" }
    )
}

# Temporarily replace Get-VM with our mock
$originalGetVM = Get-Command Get-VM -ErrorAction SilentlyContinue
if ($originalGetVM) {
    Remove-Item Function:\Get-VM -ErrorAction SilentlyContinue
}
New-Item -Path Function:\Get-VM -Value { Mock-Get-VM }

$reverseMappingTests = @(
    @{ SafeName = "SQL_Production_"; ExpectedOriginal = "SQL(Production)" },
    @{ SafeName = "Web_Test_"; ExpectedOriginal = "Web[Test]" },
    @{ SafeName = "App_Server"; ExpectedOriginal = "App/Server" },
    @{ SafeName = "Normal-VM"; ExpectedOriginal = "Normal-VM" },
    @{ SafeName = "NonExistent_VM"; ExpectedOriginal = "NonExistent_VM" }
)

$reversePassed = 0
$reverseFailed = 0

foreach ($test in $reverseMappingTests) {
    try {
        $result = Get-OriginalVMName $test.SafeName
        if ($result -eq $test.ExpectedOriginal) {
            Write-Host "✓ PASS: Reverse map '$($test.SafeName)' → '$result'" -ForegroundColor Green
            $reversePassed++
        } else {
            Write-Host "✗ FAIL: Reverse map '$($test.SafeName)' → '$result' (expected: '$($test.ExpectedOriginal)')" -ForegroundColor Red
            $reverseFailed++
        }
    }
    catch {
        Write-Host "✗ ERROR: Reverse map '$($test.SafeName)' failed: $($_.Exception.Message)" -ForegroundColor Red
        $reverseFailed++
    }
}

# Restore original Get-VM if it existed
Remove-Item Function:\Get-VM -ErrorAction SilentlyContinue
if ($originalGetVM) {
    Set-Item -Path Function:\Get-VM -Value $originalGetVM.Definition
}

Write-Host "`nReverse Mapping Test Results:" -ForegroundColor Yellow
Write-Host "Passed: $reversePassed" -ForegroundColor Green
Write-Host "Failed: $reverseFailed" -ForegroundColor Red

if ($reverseFailed -eq 0) {
    Write-Host "`n✓ All reverse mapping tests passed!" -ForegroundColor Green
} else {
    Write-Host "`n✗ Some reverse mapping tests failed." -ForegroundColor Red
}

Write-Host "`n=== COMPLETE TEST SUMMARY ===" -ForegroundColor Cyan
Write-Host "Sanitization tests: $passed passed, $failed failed" -ForegroundColor White
Write-Host "Reverse mapping tests: $reversePassed passed, $reverseFailed failed" -ForegroundColor White

$totalPassed = $passed + $reversePassed
$totalFailed = $failed + $reverseFailed

if ($totalFailed -eq 0) {
    Write-Host "`nALL TESTS PASSED! VM name handling is working correctly." -ForegroundColor Green
} else {
    Write-Host "`n$totalFailed tests failed. Please review the implementation." -ForegroundColor Red
}