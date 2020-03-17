cd D:\Test\
$files = Get-ChildItem -Path "D:\Test\" | Where-Object {$_.Extension -eq ".xls"}
ForEach ($file in $files) {
$filenew = $file.Name + "x"
Rename-Item $file $filenew
}