####################################################################################################
$FunctionZipFileTypeByDateHString = @'
 
Zip-FileType-By-Date compresses all the files of a specified type in a specified folder
that are older than a specified number of days.  It leaves the resulting zip file in the
folder specified and then deletes the original files that have been compressed.

Usage: To compress all .txt files in the C:\Windows\Logs folder over 30 days old
       
       Zip-FileType-By-Date "C:\Windows\Logs" txt 30

       Produces a file called "C:\Windows\Logs\TXT Files Older Than 2017-07-15.zip"

'@
####################################################################################################
Function Zip-FileType-By-Date ([string]$FileFolder,[string]$FileType,[int]$DaysOld) {

Begin {
    If ($FileFolder -and $FileType -and $DaysOld) {
        Add-Type -A System.IO.Compression.FileSystem
        If (Test-Path $FileFolder) {
            $ZipBeforeDate = (Get-Date).AddDays(-$DaysOld)
            # Get the list of files to be archived
            $FilesToArchive = Get-ChildItem -Path $FileFolder\* -Include *.$FileType |
                              Where-Object { $_.LastWriteTime -le $ZipBeforeDate}
            If (-not $FilesToArchive){Write-Host "There were no files to archive"}
        }
        Else {Write-Host "Not a valid Folder name"}
    }
}
Process {
    If ($FilesToArchive) { # There are files in the folder that need archiving
        # Create the name of the archive
        $ArchiveName = "$($FileType.ToUpper()) Files" +
                       " Older Than $($ZipBeforeDate.Year)-" +
                       "$("{0:00}" -f $ZipBeforeDate.Month)-" +
                       "$("{0:00}" -f $ZipBeforeDate.Day)"
        If (Test-Path "$FileFolder\$ArchiveName"){
            Write-Host "The temporary archive folder already exists"
        }
        Else {
            # Create the temporary folder needed for the archiving
            New-Item -Path $FileFolder -Name $ArchiveName -ItemType directory
            # Move the files to be archived to the temporary folder
            $FilesToArchive | ForEach-Object {
                Move-Item -Path $_ -Destination "$FileFolder\$ArchiveName"
            }
            If (Test-Path "$FileFolder\$ArchiveName.zip"){
                Write-Host "Archive file already exists"
            }
            Else {
                # Compress the files
                [IO.Compression.ZipFile]::CreateFromDirectory("$FileFolder\$ArchiveName",
                                                              "$FileFolder\$ArchiveName.zip")
                # Remove the temporary folder
                Remove-Item -Path "$FileFolder\$ArchiveName" -Recurse -Force
            }
        }
    }
}
End {
    If (-not $FileFolder) {
        $FunctionZipFileTypeByDateHString
    }
}
}


#Zip-FileType-By-Date "C:\Users\Public\Documents\Scripts\Testing\TextFiles" txt 5000
