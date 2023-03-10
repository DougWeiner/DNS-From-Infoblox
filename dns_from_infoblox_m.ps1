#To productionize
# - change config path
# - Verify config is set to prod values
# - Copy to prod folder

clear-host
Set-PSDebug -Strict
#Add libraries
. C:\data\apps\powershell_libraries\common_functions_and_procedures.ps1
. C:\data\apps\powershell_libraries\database_functions.ps1

import-module PSRBAlib

function name_ok {
    param($local:some_device_name)
    #Function semi-neutered 07OCT2019 due to workstations being added to CDB
    if ($local:some_Device_name -notmatch ".*-oob" -and
        $local:some_Device_name -notmatch ".*-ilo") {
        $true
    } else {
        $false
    }

    #Original
    #if ($local:some_Device_name -notmatch ".*-W7L" -and
    #    $local:some_Device_name -notmatch ".*-W7D" -and
    #    $local:some_Device_name -notmatch ".*-WXL" -and
    #    $local:some_Device_name -notmatch ".*-WXD" -and
    #    $local:some_Device_name -notmatch ".*-WX" -and
    #    $local:some_Device_name -notmatch ".*-W7V" -and
    #    $local:some_Device_name -notmatch ".*-W7" -and
    #    $local:some_Device_name -notmatch ".*-\dW7" -and
    #    $local:some_Device_name -notmatch ".*-\dW7L" -and
    #    $local:some_Device_name -notmatch ".*-\dW7D" -and
    #    $local:some_Device_name -notmatch ".*-XPL" -and
    #    $local:some_Device_name -notmatch ".*-XPD" -and
    #    $local:some_Device_name -notmatch ".*-XP" -and
    #    $local:some_Device_name -notmatch ".*-vdi" -and
    #    $local:some_Device_name -notmatch ".*-oob" -and
    #    $local:some_Device_name -notmatch ".*-ilo" -and
    #    $local:some_Device_name -notmatch "BCTDW7.*" -and
    #    $local:some_Device_name -notmatch "BCTDXP.*" -and
    #    $local:some_Device_name -notmatch "BCTLW7.*" -and
    #    $local:some_Device_name -notmatch "BCTLXP.*" -and
    #    $local:some_Device_name -notmatch "ALATRAINING-.*" -and
    #    $local:some_Device_name -notmatch "ALA.*W7") {
    #    $true
    #} else {
    #    $false
    #}
}
$fatal_error = ""
#Load variables from config file (must be in same folder this runs from, named scriptname.cfg (not .ps1))
$script_fullname = $MyInvocation.MyCommand.source
$script_name = ($MyInvocation.MyCommand.Name).replace('.ps1','')
$config = gc ((split-path $script:MyInvocation.MyCommand.Path) + "\$script_name.cfg")
$params=@{}
foreach ($line in $config) {
    $line=$line.trim()
    if ($line.Length -ne 0) {
        $line=$line.replace("`t",'') #tabs
        if ($line.substring(0,1) -ne '#') {
            ($param, $value) = $line.split('|')
            $params.add($param, $value)
        }
    }
}

#Set log_file path and name
$date_for_file = (Get-Date -Format 'yyyy-MM-dd-HHmm')
$date_for_email = get-date
$log_file = ($params.log_path + $date_for_file + "_DNS_from_InfoBlox.log").ToUpper()
loggit $log_file "Start"

#Log the configuration
foreach ($line in $config) {
    $line=$line.trim()
    if ($line.Length -ne 0) {
        $line=$line.replace("`t",'') #tabs
        if ($line.substring(0,1) -ne '#') {
            ($param, $value) = $line.split('|')
            loggit $log_file "$param = $value"
        }
    }
}

$IBuser = PSRBA_decrypt_string (gc $params.ibu)
$IBPassword = ConvertTo-SecureString (PSRBA_decrypt_string (gc $params.ibp)) -AsPlainText -Force
$DBUser = PSRBA_decrypt_string (gc $params.myu)
$DBPassword = PSRBA_decrypt_string (gc $params.myp)
$credential = New-Object System.Management.Automation.PSCredential $IBuser, $IBpassword #create credential object.  User is domain_name\domain_user or server_name\local_user
$ukrisk_user = PSRBA_decrypt_string (gc $params.ukrisk_u)
$ukrisk_pass = PSRBA_decrypt_string (gc $params.ukrisk_p)
$ukrisk_creds = New-Object System.Management.Automation.PSCredential ($ukrisk_user, (ConvertTo-SecureString $ukrisk_pass -AsPlainText -Force))
Set-IBConfig -ProfileName 'mygrid' -WAPIHost $params.ib_host -WAPIVersion 'latest' -Credential $credential -SkipCertificateCheck
$error.Clear() #For some reason the IB module throws a silent error each and every time
#Initialize some variables
$inserted_records = @{} #This is used to track what is inserted in order to prevent duplicates.
$ip_addresses = @{}
$a_records = @{}
$iblox_a_record_count = 0
$iblox_host_record_count = 0
$a_records_filtered_by_name = 0
$iblox_cname_record_count = 0
$cname_records_filtered_by_name = 0
$total_records_from_infoblox = 0
$a_record_inserts = 0
$cname_record_inserts = 0
$hpcc_inserts = 0
$ukrisk_inserts = 0
$total_inserts = 0
loggit $log_file "Retrieving A records from infoBlox"
try {
    $host_recs = Get-IBObject -type record:a -ReturnAllFields #-MaxResults 50 #Only use -Maxresults for testing
} catch {
    $fatal_error = "Error retrieving A records"
    loggit $log_file $fatal_error
}
if ($fatal_error -eq "") {
    loggit $log_file "End getting A records from infoblox, processing"
    $total_records_from_infoblox += $host_recs.count
    $iblox_a_record_count = $host_recs.count
    foreach ($iblox_rec in $host_recs) {
        #Filter out junk - not perfect, but it filters a ton of them
        if (name_ok $iblox_rec.dns_name) {
            #Record the name/Ip combo
            if ($a_records.($iblox_rec.dns_name) -eq $null) {
                $a_records.add($iblox_rec.dns_name, @($iblox_rec.ipv4addr))
            } else {
                $a_records.($iblox_rec.dns_name) +=  ($iblox_rec.ipv4addr)
            }
            #Record the IP/Name combo
            if ($ip_addresses.($iblox_rec.ipv4addr) -eq $null) {
                $ip_addresses.add($iblox_rec.ipv4addr, @($iblox_rec.dns_name))
            } else {
                $ip_addresses.($iblox_rec.ipv4addr) +=  $iblox_rec.dns_name
            }
        } else {
            loggit $log_file ("A record filtered:" + $iblox_rec.dns_name)
            $a_records_filtered_by_name++
        }
    }
    #Get HOST records.  We'll treat them the same as A records and store in $A_records
    $host_recs = Get-IBObject -type record:host -ReturnAllFields #-filters 'name:=alaldinf011.choicepoint.net' #-MaxResults 50
    foreach ($iblox_rec in $host_recs) {
        if (name_ok $iblox_rec.name) {
            foreach ($ipv4_record in $iblox_rec.ipv4addrs) {
                #($iblox_rec.name + "`t" + $ipv4_record.ipv4addr)
                #Filter out junk - not perfect, but it filters a ton of them
                #Record the name/Ip combo
                if ($a_records.($iblox_rec.name) -eq $null) {
                    $a_records.add($iblox_rec.name, @($ipv4_record.ipv4addr))
                    $iblox_host_record_count++
                } else {
                    $a_records.($iblox_rec.name) +=  ($ipv4_record.ipv4addr)
                    $iblox_host_record_count++
                }
                #Record the IP/Name combo
                if ($ip_addresses.($ipv4_record.ipv4addr) -eq $null) {
                    $ip_addresses.add($ipv4_record.ipv4addr, @($iblox_rec.name))
                } else {
                    $ip_addresses.($ipv4_record.ipv4addr) +=  $iblox_rec.name
                }
            }
        } else {
            loggit $log_file ("HOST record filtered:" + $iblox_rec.name)
            $a_records_filtered_by_name++
        }
    }

    #CNAME records
    $c_names = @{}
    $c_names_no_canonical = @{}
    loggit $log_file "Getting CNAME records"
    $host_recs = Get-IBObject -type record:cname -ReturnAllFields #-MaxResults 50
    loggit $log_file  "End getting CNAME records from infoblox, processing"
    $total_records_from_infoblox += $host_recs.count
    $iblox_cname_record_count = $host_recs.count
    foreach ($iblox_rec in $host_recs) {
        #Filter out junk we dont want (like desktops/laptops)
        if (name_ok $iblox_rec.dns_name) {
            #Check if there's an A record
            if ($a_records.($iblox_rec.dns_canonical)) {
                #We have the IP address for the canonical name ('target' of the alias)
                if ($c_names.($iblox_rec.dns_name) -eq $null) {
                    $c_names.add($iblox_rec.dns_name,@($a_records.($iblox_rec.dns_canonical)))
                } else {
                    $c_names.($iblox_rec.dns_name) += ($a_records.($iblox_rec.dns_canonical))
                }
            } else {
                #We do not have an IP address from it in infoblox
                loggit $log_file ("CNAME without corresponding A record.  CNAME=" +  $iblox_rec.dns_name + ", CANONICAL=" + $iblox_rec.dns_canonical)
                if ($c_names_no_canonical.($iblox_rec.dns_name) -eq $null) {
                    $c_names_no_canonical.add($iblox_rec.dns_name,@($iblox_rec.dns_canonical))
                } else {
                    $c_names_no_canonical.($iblox_rec.dns_name) += ($iblox_rec.dns_canonical)
                }
            }
        } else {
            loggit $log_file ("CNAME record filtered:" + $iblox_rec.dns_name)
            $cname_records_filtered_by_name++
        }
    }

    #A records
    loggit $log_file "Done processing, adding to DB"
    $updatetime = get-date -format 'yyyy-MM-dd HH:mm:ss'
    $DBConnectionString = ($params.cdb_data_source + ";uid=$DBUser;pwd='$DBPassword'")
    try {
        $DBConn = PSRBA_OpenMySQLConnection $DBConnectionString
    } catch {
        $fatal_error = "Error opening DB connection"
        loggit $log_file $fatal_error
    }
    if ($fatal_error -eq "") {
        loggit $log_file "Deleting existing records"
        $sql = "DELETE FROM F5_INTERNALDNS"
        if ($params.safety -eq "false") {
            PSRBA_MySQLQuery $DBConn $sql
            PSRBA_MySQLQuery $DBConn "SET time_zone = 'US/Eastern';"
        }
        #Add A records
        foreach ($key in $a_records.keys) {
            foreach ($ip_address in $a_records.$key) {
                #Check if it has already been inserted
                if ($null -eq $inserted_records.$("$key$ip_address") ) {
                    $a_record_inserts++
                    $total_inserts++
                    $sql = ("insert into f5_internaldns (RECORD,IP,UPDATETIME) VALUES ('" + $key.ToLower() + "','" + $ip_address + "','$updatetime')")
                    $sql
                    if ($params.safety -eq "false") {
                        PSRBA_MySQLQuery $DBConn $sql
                    }
                    #Add to hash 
                    $inserted_records.add("$key$ip_address",1)
                } else {
                    #Do nothing, it's already in the table
                    $debug = 1  #benign statement to allow for a debug stop
                }
            }
        }

        #Add C records
        foreach ($key in $c_names.keys) {
            foreach ($ip_address in $c_names.$key) {
                #Check if it has already been inserted
                if ($null -eq $inserted_records.$("$key$ip_address") ) {
                    $sql = ("insert into f5_internaldns (RECORD,IP,UPDATETIME) VALUES ('" + $key.ToLower() + "','" + $ip_address + "','$updatetime')")
                    $cname_record_inserts++
                    $total_inserts++
                    $sql
                    if ($params.safety -eq "false") {
                        PSRBA_MySQLQuery $DBConn $sql
                    }
                    $inserted_records.add("$key$ip_address",1)
                } else {
                    #Do nothing, it's already in the table
                }
            }
        }

        #Add UKRisk records.  These are retrieved from a Windows DNS server
        loggit $log_file "Querying ukrisk.net DNS"
        $cs = New-CimSession -Credential $ukrisk_creds -ComputerName p-ad01.ukrisk.net
        $ukrisk_recs = Get-DnsServerResourceRecord -ComputerName p-ad01.ukrisk.net -zonename 'ukrisk.net' -CimSession $cs -RRType 'A'
        foreach($record in $ukrisk_recs) {
            #Check if it has already been inserted
            if ($null -eq $inserted_records.$("$($record.hostname)($record.RecordData.IPv4Address)")) {
                $total_inserts++
                $ukrisk_inserts++
                $ukrisk_fqdn = 
                "$($record.hostname)`t$($record.RecordData.IPv4Address)"
                $sql = ("insert into f5_internaldns (RECORD,IP,UPDATETIME) VALUES ('$($record.HostName.ToLower()).ukrisk.net','$($record.RecordData.IPv4Address)','$updatetime')")
                loggit $log_file $sql
                PSRBA_MySQLQuery $DBConn $sql
                $inserted_records.ADD($("$($record.hostname)($record.RecordData.IPv4Address)"),1)
            } else {
                #Do nothing, it's already in the table
            }
        }
        $cs.Close()
        #Add HPCC and other devices listed in CDB by IP address.  DNS records do not exist for these and as such "fake" DNS records need to be inserted
        $sql = "SELECT device_name FROM devices WHERE status <> 'RETIRED' and REGEXP_LIKE(device_name, '^(([0-9]{1}|[0-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.){3}([0-9]{1}|[0-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$')"
        $IP_devices = PSRBA_MySQLQuery $DBConn $sql
        foreach ($IP_device in $IP_devices) {
            $hpcc_inserts++
            $total_inserts++
            $sql = ("insert into f5_internaldns (RECORD,IP,UPDATETIME) VALUES ('" + $IP_device.DEVICE_NAME + "','" + $IP_device.DEVICE_NAME + "','$updatetime')")
            PSRBA_MySQLQuery $DBConn $sql
        }
    }
}
$DBConn.close()
if ($fatal_error -ne "") {
    loggit $log_file "Fatal error: $fatal_error"
    Send-MailMessage -to $params.error_email_alert_recipients -from $params.email_from -Subject ("Internal DNS data gather failed on " + [System.Net.DNS]::GetHostByName('').HostName) -body $fatal_error

} else {
    #Get stats
    $email_body = '<!DOCTYPE html><html>
                <head>
                <style>
                table {
                    font-family: arial, sans-serif;
                    border-collapse: collapse;
                    width:50%;
                }
                td {
                    border: 2px solid #dddddd;
                    text-align: left;
                    padding: 8px;
                }
                th {
                    border: 2px solid #dddddd;
                    text-align: center;
                    padding: 8px;
                }
                tr:nth-child(even) {
                    background-color: #dddddd;
                }
                </style>
                </head>
                <body><table><th colspan=2>INT DNS Data Gather</th>'

    $email_body += ('<tr><td>Run time</td><td>' + $date_for_email + '</td></tr>')
    $email_body += ('<tr><td>InfoBlox records processed</td><td>' + '{0:N0}' -f $total_records_from_infoblox + '</td></tr>')
    $email_body += ('<tr><td>InfoBlox A records processed</td><td>' + '{0:N0}' -f $iblox_a_record_count + '</td></tr>')
    $email_body += ('<tr><td>InfoBlox HOST records processed</td><td>' + '{0:N0}' -f $iblox_host_record_count + '</td></tr>')
    $email_body += ('<tr><td>A/HOST records filtered out by name</td><td>' + '{0:N0}' -f $a_records_filtered_by_name + '</td></tr>')
    $email_body += ('<tr><td>A/HOST record IPs inserted</td><td>' + '{0:N0}' -f $a_record_inserts + '</td></tr>')
    $email_body += ('<tr><td>InfoBlox CNAME records processed</td><td>' + '{0:N0}' -f $iblox_cname_record_count + '</td></tr>')
    $email_body += ('<tr><td>CNAME records filtered out by name</td><td>' + '{0:N0}' -f $cname_records_filtered_by_name + '</td></tr>')
    $email_body += ('<tr><td>CNAME records without corresponding A records</td><td>' + '{0:N0}' -f $c_names_no_canonical.Count + '</td></tr>')
    $email_body += ('<tr><td>CNAME IP records inserted</td><td>' + '{0:N0}' -f $cname_record_inserts + '</td></tr>')
    $email_body += ('<tr><td>UKRISK.NET IP records inserted</td><td>' + '{0:N0}' -f $ukrisk_inserts + '</td></tr>')
    $email_body += ('<tr><td>HPCC/IP device names inserted</td><td>' + '{0:N0}' -f $hpcc_inserts + '</td></tr>')
    $email_body += ('<tr><td>Total DB inserts</td><td>' + '{0:N0}' -f $total_inserts + '</td></tr>')
    $email_body += '</table>'
    $email_body += "<br><br>$script_fullname</body></html>"

    Send-MailMessage -to $params.error_email_alert_recipients -from $params.email_from -subject ('Internal DNS data gather summary from ' + [System.Net.DNS]::GetHostByName('').HostName) -BodyAsHtml $email_body  -SmtpServer appmail
}
loggit $log_file "Finished"

#RECORD                                              IP                                                  UPDATETIME                                
#--------------------------------------------------------------------------------------------------------------------------------------------------
#otp004020ots.choicepoint.net                        10.26.163.9                                         1518812776   


#Supported Objects:

#allrecords                   ipv6networkcontainer         record:cname                 sharedrecord:a
#csvimporttask                ipv6range                    record:host                  sharedrecord:aaaa
#discovery:device             ipv6sharednetwork            record:host_ipv4addr         sharedrecord:mx
#discovery:deviceinterface    lease                        record:host_ipv6addr         sharedrecord:srv
#discovery:deviceneighbor     macfilteraddress             record:mx                    sharedrecord:txt
#discovery:status             member                       record:naptr                 snmpuser
#fileop                       namedacl                     record:ptr                   view
#fixedaddress                 network                      record:srv                   zone_auth
#grid                         networkcontainer             record:txt                   zone_delegated
#grid:dhcpproperties          networkview                  restartservicestatus         zone_forward
#ipv4address                  permission                   roaminghost                  zone_stub
#ipv6address                  range                        scheduledtask
#ipv6fixedaddress             record:a                     search
#ipv6network                  record:aaaa                  sharednetwork