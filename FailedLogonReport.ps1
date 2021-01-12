param ($reportList="c:\tools\config\failedLogonReportList.csv",$failedLogonReportPath="C:\Users\SECCOMP\Desktop\NetWrix Reports", $outputPath='E:\Data\Reports\FailedLogons')

# --------------------------------- functions ---------------------------------------

# write to stdout and append to specified file
function write-Host-and-File ($myObject,$logFileOutput=$null,$color='White') 
{
  write-Host $myObject -ForegroundColor $color
  if ($logFileOutput)
  {
    write-output $myObject | out-file -append $logFileOutput
  }
}


# ----------------------------------------

$SMTPServer = "localhost"  
$FromAddress = "noreply@iongroup.com"

$dateString = get-date -f "yyyy-MM-dd"
$logPath = 'e:\data\logs'
if (!(test-path $logPath))
{
  mkdir $logPath
}

$logFile = (join-path $logPath ("FailedLogons-$dateString.log"))
$transcriptFile = (join-path $logPath ("FailedLogons-transcript-$dateString.log"))

start-transcript $transcriptFile

if (!(test-path $failedLogonReportPath))
{
  write-Host-and-File "Ensure you specify a valid report path" $logFile
  Stop-Transcript
  break
}

$failedLogonReport = gci -path $failedLogonReportPath -Filter "*Failed Logons*" | sort -Property LastWriteTime | select -Last 1

if ($failedLogonReport.LastWriteTime -lt ((Get-Date).AddHours(-23)))
{
  write-Host-and-File "Report not updated recently!" $logFile
  Stop-Transcript
  break
}

if (!$failedLogonReport -or !(test-path $failedLogonReport.FullName))
{
  write-Host-and-File "Ensure you specify a valid report file" $logFile
  Stop-Transcript
  break
}

if (!$reportList -or !(test-path $reportList))
{
  write-Host-and-File "Ensure you specify a valid report list file" $logFile
  Stop-Transcript
  break
}

if (!(test-path $outputPath))
{
  mkdir $outputPath
}


# only look at reports for WSSASPAD02
$reports = (import-csv $reportList) | ? { $_.ADOU -like '*WSSASPAD02*'}

$failedLogonEntries = import-csv $failedLogonReport.FullName

# SAML group
$group = 'SAML_ACCT_LOCKOUT_EXEMPTION'
$members = Get-ADGroupMember -Identity $group -Recursive | Select -ExpandProperty samAccountName

# Exclude SAML users
$failedLogons = $failedLogonEntries | ? {(split-path -Leaf $_.who) -notin $members}

ForEach ($entry in $failedLogons)
{
  # ensure "when" column is converted to date-time
  $entry.When = Get-Date $entry.When
  $logonID = split-path -Leaf $entry.Who
  $adUser = get-adUser -Filter ('samAccountName -eq "' + $logonID + '"') -Properties CanonicalName
  if ($adUser)
  {
    $cn = $adUser.CanonicalName
  }
  else
  {
    $cn = 'N/A'
  }
  $entry | Add-Member -MemberType NoteProperty -Name 'CN' -Value $cn
}

$allFailedLogons = join-path $outputPath ('AllFailedLogons.csv')
$failedLogons | Export-CSV $allFailedLogons -NoTypeInformation
# email Full report
$EmailAddress = @('wayne.gjaltema@iongroup.com')
$MessageSubject = "WSSASPAD02 failed logon report"
$emailMessage = @"
WSSASPAD02 failed logon report

See attached CSV file.
"@

Send-MailMessage -From $FromAddress -To $EmailAddress -Subject $MessageSubject `
 -Body $emailMessage -SmtpServer $SMTPServer -Attachments $allFailedLogons  

ForEach ($report in $reports)
{
  $reportFile = join-path $outputPath ($report.Report + '.csv')
  if (test-path $reportFile)
  {
    remove-item $reportFile
  }
  $specificFailedLogons = $failedLogons | ? { $_.CN -like "*$($report.ADOU)*"} 
  if ($specificFailedLogons -and $specificFailedLogons.count -gt 0)
  {
    $specificFailedLogons| select * -Exclude CN |Export-CSV $reportFile -NoTypeInformation
    # email report
    $EmailAddress = $report.Recipients -split ','
    $MessageSubject = $report.Report
    $emailMessage = @"
$($report.Report)

See attached CSV file.
"@

    Send-MailMessage -From $FromAddress -To $EmailAddress -Subject $MessageSubject `
     -Body $emailMessage -SmtpServer $SMTPServer -Attachments $reportFile  
  }
  else  # No failed logons
  {
    $EmailAddress = $report.Recipients -split ','
    $MessageSubject = $report.Report
    $emailMessage = @"
$($report.Report)

No failed logins.
"@

    Send-MailMessage -From $FromAddress -To $EmailAddress -Subject $MessageSubject `
     -Body $emailMessage -SmtpServer $SMTPServer  
  
  }
}
Stop-Transcript