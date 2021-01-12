#NAME: LogPurgingLatest.ps1#
#AUTHOR: Ripu Daman Rai
#DATE: 17/08/2018

#Getting Path of All the Servers
$Inputs = Get-Content -Path "E:\SSB_Log_Rotation_DoNotDelete\input.txt"

#Defining FolderName
$folderName = "Archive"

foreach ( $Input in $Inputs)
{

#Creating Archive Directory
$ArchivePath = Get-ChildItem -path "$Input\Logs\*\" | select fullname | ForEach-Object {$_.fullname}

foreach ($Path in $ArchivePath)
{
#Checking if Folder Exists
If(!(test-path -Path "$Path\Archive"))
 {
    New-Item -Type Directory -Path $Path -Name $folderName
 }

 #Skipping the Folder Creation
else
 {
    Echo "Directory Exists"
 }
}

#Getting path of the LOGS directory
$Paths = Get-ChildItem -path "$Input\Logs\*\LOGS\" | select fullname | ForEach-Object {$_.fullname}

#Setting Limit to 30 days 
$limit = (Get-Date).AddDays(-30)

foreach ($Path in $Paths)

{
    cd $Path
#Compressing the Log Folder
    Compress-Archive "$Path\*" -CompressionLevel Fastest -DestinationPath ('LOGS-' + (get-date -Format yyyyMMdd) + '.zip')
    cd ..
    $CurrentLocation = Get-Location
#Moving Zipped Log Folder to Archive Folder
    Move-Item -Path "$Path\*.zip" -Destination "$CurrentLocation\Archive" -Force
}

foreach ($Path in $Paths)
{
    cd $Path
    Remove-Item * -Force -Recurse -exclude *.zip
}  

foreach ($Path in "$ArchivePath\Archive")

{

    cd $Path
    Get-ChildItem -include *.zip $Path1 -Recurse | Where-Object { $_.LastWriteTime -lt $limit } | Where-Object { -not ($_.psiscontainer) } | Foreach-Object {Remove-Item $_.FullName}
}

}