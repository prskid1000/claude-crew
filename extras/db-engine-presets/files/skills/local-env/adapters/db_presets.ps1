#Requires -Version 7
# db-engine-presets (extra): dot-sourced by localenv.ps1; fills the db hooks an env leaves unset for envs.<env>.db.engine
# db.engine presets fill the db hooks an env leaves unset: {H} {P} {U} {N} {URI} = db host, port, user, name, uri; {snapDir}
& { $q = '-h {H} -p {P} -U {U}'; $my = '-h {H} -P {P} -u {U}'; $ss = 'sqlcmd -S {H},{P} -U {U}'; $sf = '"{snapDir}/{snapshot}'; $sb = '{N}_{suffix}'; $o = '{U}@{H}:{P}/{N} schemas={U} directory=DATA_PUMP_DIR dumpfile={snapshot}.dmp'
$script:DbPresets = @{
  postgres  = @{ port = 5432; snapshot = "pg_dump -Fc $q -f $sf.dump`" {N}"; restore = "pg_restore --clean --if-exists $q -d {N} $sf.dump`""; query = "psql $q -d {N} -At -c `"{sql}`""
                exec = "psql $q -d {N} -v ON_ERROR_STOP=1 -f {file}"; clone = "createdb $q -T {N} $sb"; drop = "dropdb --if-exists $q $sb" }
  mysql     = @{ port = 3306; snapshot = "mysqldump --single-transaction --routines --triggers $my {N} > $sf.sql`""; restore = "mysql $my {N} < $sf.sql`""; query = "mysql $my -N -e `"{sql}`" {N}"
                exec = "mysql $my {N} < {file}"; clone = "mysql $my -e `"CREATE DATABASE $sb`" && mysqldump $my {N} | mysql $my $sb"; drop = "mysql $my -e `"DROP DATABASE IF EXISTS $sb`"" }
  sqlserver = @{ port = 1433; snapshot = "$ss -b -Q `"BACKUP DATABASE [{N}] TO DISK=N'{snapDir}/{snapshot}.bak' WITH INIT`""; restore = "$ss -b -Q `"RESTORE DATABASE [{N}] FROM DISK=N'{snapDir}/{snapshot}.bak' WITH REPLACE`""
                query = "$ss -d {N} -h -1 -Q `"{sql}`""; exec = "$ss -d {N} -b -i {file}" }
  sqlite    = @{ snapshot = "sqlite3 `"{N}`" `".backup '{snapDir}/{snapshot}.db'`""; restore = "sqlite3 `"{N}`" `".restore '{snapDir}/{snapshot}.db'`""; query = "sqlite3 `"{N}`" `"{sql}`""
                exec = "sqlite3 `"{N}`" `".read {file}`""; clone = "sqlite3 `"{N}`" `".backup '{N}.{suffix}'`"" }
  oracle    = @{ port = 1521; snapshot = "expdp $o reuse_dumpfiles=y"; restore = "impdp $o table_exists_action=replace"; exec = "sqlplus -s -l {U}@{H}:{P}/{N} @{file}" }
  mongodb   = @{ port = 27017; snapshot = "mongodump --uri `"{URI}`" --gzip --archive=$sf.gz`""; restore = "mongorestore --uri `"{URI}`" --drop --gzip --archive=$sf.gz`""; query = "mongosh `"{URI}`" --quiet --eval `"{sql}`""
                clone = "mongodump --uri `"{URI}`" --archive | mongorestore --uri `"{URI}`" --archive --nsFrom `"{N}.*`" --nsTo `"$sb.*`""; drop = "mongosh `"{URI}`" --quiet --eval `"db.getSiblingDB('$sb').dropDatabase()`"" }
}
$script:DbPresets.mariadb = $script:DbPresets.mysql
$script:DbAlias = @{ postgresql = 'postgres'; pg = 'postgres'; mssql = 'sqlserver'; mongo = 'mongodb' }
foreach ($n in $(if ($script:LE.envs) { @($script:LE.envs.PSObject.Properties.Name) })) {
  $db = $script:LE.envs.$n.db; if ($db.engine -and $script:DbAlias["$($db.engine)".ToLower()]) { $db.engine = $script:DbAlias["$($db.engine)".ToLower()] }; $p = if ($db.engine) { $script:DbPresets["$($db.engine)".ToLower()] }; if (-not $p) { continue }
  $port = if ($db.port) { $db.port } else { $p.port }; $sd = (Join-Path (Get-KitPath localenv-env) 'snapshots').Replace('\', '/')
  $h = if ($db.host) { $db.host } else { '127.0.0.1' }; $v = @{ H = $h; P = $port; U = "$($db.user)"; N = "$($db.name)"; snapDir = $sd
          URI = $(if ($db.uri) { $db.uri } else { "mongodb://${h}:$port/$($db.name)" }) }
  foreach ($k in 'snapshot', 'restore', 'query', 'exec') {
    $o = $db; if (-not $p.$k) { continue }
    if (-not $o.$k) { $c = $p.$k; foreach ($x in $v.Keys) { $c = $c.Replace("{$x}", "$($v[$x])") }; $o | Add-Member $k $c -Force }
  }
  if ($p.snapshot) { New-Item -ItemType Directory -Force $sd | Out-Null }
} }
