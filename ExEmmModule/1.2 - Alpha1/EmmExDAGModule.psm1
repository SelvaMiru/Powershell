﻿<#PSScriptInfo
.VERSION 1.2
.AUTHOR Faris Malaeb
.PROJECTURI https://www.powershellcenter.com/
.DESCRIPTION 
 This Powershell module will Place your Exchange Server DAG in maintenance Mode
 Also you can remove Exchange DAG from Maintenance Mode.
 Available Commands
    Start-EMMDAGEnabled: Set your Exchange Server to be in Maintenance Mode.
    Stop-EMMDAGEnabled: Remove Exchange from maintenanace Mode
    Test-EMMReadiness: Test the environment for readiness to go in maintenance Mode
   

#> 
Function Check-ScriptReadiness{
param(
$ServerName,
$AltServer
)
        if (((Test-NetConnection -Port 80 -ComputerName $PSBoundParameters['ServerName']).TcpTestSucceeded -like $true) -and (Test-NetConnection -Port 80 -ComputerName $PSBoundParameters['AltServer']).TcpTestSucceeded -like $true){
        $isadmin=[bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-544")
        switch ($isadmin)
        {
            $true {return 1}
            $false {return 0}
           
        }
       
       }
       Else{
        write-host "Operation failed, please check if the computer and the Alternative Server are reachable" -ForegroundColor Red
        Write-host  $Error[0]
        break
       }


}

Function Start-EMMDAGEnabled {
   
    Param(
        [parameter(mandatory=$false,ValueFromPipeline=$true,Position=0)]$ServerForMaintenance,
        [parameter(mandatory=$false)][ValidatePattern("(?=^.{1,254}$)(^(?:(?!\d+\.|-)[a-zA-Z0-9_\-]{1,63}(?<!-)\.?)+(?:[a-zA-Z]{2,})$)")][string]$ReplacementServerFQDN,
        [parameter(Mandatory=$false)][switch]$IgnoreQueue,
        [parameter(Mandatory=$false)][switch]$IgnoreCluster,
        [parameter(Mandatory=$false)][switch]$SkipDatabaseHealthCheck

    )

        Begin{
        #$Global:ScriptScope=$True
        AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Checking Readiness... Please wait" -MessageColor Yellow -ProgressState "Starting" -ProgressPercent 3 
            $ErrorActionPreference="Stop"
            $ReadyToExecute=Check-ScriptReadiness -ServerName $PSBoundParameters['ServerForMaintenance'] -AltServer $PSBoundParameters['ReplacementServerFQDN']
            if ($ReadyToExecute -eq 0){Write-Host "Please Make sure that you execute Powershell as Admin" -ForegroundColor Red
                return
            }
        [hashtable]$ExMainProgress=[ordered]@{}
        if ($PSBoundParameters.ContainsKey('SkipDatabaseHealthCheck')){
        AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "DB Health check will be ignored as the -SkipDatabaseHealthCheck is selected.`nIts a recommended to use this option in production environment." -MessageColor White
        Write-Host "Please check the online manual and ensure to follow the best practices"
        }
        }

        Process{
            AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Preparing $($PSBoundParameters['ServerForMaintenance']) to be placed in Maintinance Mode" -MessageColor Yellow -ProgressState "Turnning Off HubTransport Activities..."  -ProgressPercent 10 
            $Step1=Set-EMMHubTransportState -Servername $PSBoundParameters['ServerForMaintenance'] -Status Draining
            AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Will Now Check Queue Service Readiness" -MessageColor Yellow -ProgressState "Turnning Off HubTransport Activities..." -ProgressPercent 15
            switch ($PSBoundParameters.Containskey('IgnoreQueue')){
            $true {write-host "Queue Check... Skipped";$step2="Message Transfer Skipped with Queue Check"}
            $false{
                AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Message Redirection Process will Start" -MessageColor Yellow -ProgressState "Redirecting Messages..." -ProgressPercent 25 
                AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "This might take few minuts, Please wait.." -MessageColor Yellow 
                $step2=Start-EMMRedirectMessage -SourceServer $PSBoundParameters['ServerForMaintenance'] -ToServer $PSBoundParameters['ReplacementServerFQDN']
            }
            }
            Switch($PSBoundParameters.Containskey('IgnoreCluster')){
                        $true { AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Skipping Cluster MGMT as user requests." -MessageColor Yellow -ProgressState "Skipping Cluster" -ProgressPercent 50
                                $step3="Skipped"}
                        $false { AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Starting Cluster MGMT." -MessageColor Yellow -ProgressState "Pausing $($PSBoundParameters['ServerForMaintenance']) " -ProgressPercent 50
                                $step3=Set-EMMClusterConfig -ClusterNode $PSBoundParameters['ServerForMaintenance'] -PauseOrResume PauseThisNode}
                    }
            AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Starting Exchange Database Managment" -MessageColor Yellow -ProgressState "Moving Database to another node" -ProgressPercent 70
            switch ($PSBoundParameters.Containskey('SkipDatabaseHealthCheck')){
            ####### ERROR
            $true {Set-EMMDBActivationMoveNow -ServerName $PSBoundParameters['ServerForMaintenance'] -ActivationMode BlockMode -TimeoutBeforeManualMove 120 -SkipValidation}
            $false {Set-EMMDBActivationMoveNow -ServerName $PSBoundParameters['ServerForMaintenance'] -ActivationMode BlockMode -TimeoutBeforeManualMove 120  }
            }
            
            AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Switching ServerComponentState ServerWideOffline to Off" -MessageColor Yellow -ProgressState "Updating ServerWideOffline" -ProgressPercent 95
            Set-ServerComponentState $PSBoundParameters['ServerForMaintenance'] -Component ServerWideOffline -State Inactive -Requester Maintenance -ErrorAction Stop
            $step5=get-ServerComponentState $PSBoundParameters['ServerForMaintenance'] -Component ServerWideOffline
            Start-Sleep 3
            Write-Host "All Commands are completed, and below are the result...`n"-ForegroundColor Yellow
            $ExMainProgress.Add("HubTransport Draining",$Step1)
            $ExMainProgress.Add("Queue Length Status",(Get-Queue -server $PSBoundParameters['ServerForMaintenance'] | Where-Object {($_.DeliveryType -notlike "Shadow*") -and ($_.DeliveryType -notlike "Undefined") }| Select-Object Messagecount | Measure-Object -Sum -Property MessageCount).Sum)
            $ExMainProgress.Add("Cluster Node",$step3)
            $ExMainProgress.Add("Activation Policy",(Get-MailboxServer -Identity $PSBoundParameters['ServerForMaintenance']).DatabaseCopyAutoActivationPolicy)
            $ExMainProgress.Add("ServerWide",$step5.State)

        }
        
        End{
       Return $ExMainProgress | Format-Table -AutoSize -Wrap


        }
}
Export-ModuleMember Start-EmmDAGEnabled

Function AddEmptylines{
param(
    [parameter(mandatory=$true)]$numberoflines,
    [parameter(mandatory=$true)]$MessageToIncludeAtTheEnd,
    [parameter(mandatory=$True)]$MessageColor,
    [parameter(mandatory=$false)]$ProgressState,
    [parameter(mandatory=$false)]$ProgressPercent


    )
    $numofline=0
    while($numofline -lt $PSBoundParameters['numberoflines']){
        Write-Host ""
        $numofline++
    }
    Write-Host $($PSBoundParameters['MessageToIncludeAtTheEnd']) -ForegroundColor $PSBoundParameters['MessageColor']
    if ($PSBoundParameters['ProgressState']){
    Write-Progress -Activity $PSBoundParameters['MessageToIncludeAtTheEnd'] -Status $PSBoundParameters['ProgressState'] -PercentComplete $PSBoundParameters['ProgressPercent']
    }
    
}

Function Stop-EMMDAGEnabled {
   
    Param(
        [parameter(mandatory=$false,ValueFromPipeline=$true,Position=0)]$ServerInMaintenance,
        [parameter(Mandatory=$false)][switch]$IgnoreCluster,
        [parameter(mandatory=$false)][validateset("IntrasiteOnly","Unrestricted")]$ServerActivationMode="Unrestricted"
        
    )

        Begin{
            $ErrorActionPreference="Stop"
            [hashtable]$ExOutMainProgress=[ordered]@{}
        }

        Process{
            Write-Host "Preparing $($PSBoundParameters['ServerInMaintenance']) for Activation..." -ForegroundColor Yellow 
            AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Taking the Server Out of Maintenance mode..." -MessageColor Yellow -ProgressState "Enabling ServerWideOffline component" -ProgressPercent 15
            Set-ServerComponentState $PSBoundParameters['ServerInMaintenance'] -Component ServerWideOffline -State active -Requester Maintenance
            AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Configuring cluster if required..." -MessageColor Yellow -ProgressState "Cluster Configuration" -ProgressPercent 35
            switch($PSBoundParameters.Containskey('IgnoreCluster')){
                $true {write-host "Cluster Config are Skipped";$outstep1="Skipped"}
                $false {$outstep1=Set-EMMClusterConfig -ClusterNode $PSBoundParameters['ServerInMaintenance'] -PauseOrResume ResumeThisNode}
            }

            $outStep2=Set-EMMDBActivationMoveNow -ServerName $PSBoundParameters['ServerInMaintenance'] -ActivationMode $ServerActivationMode
            AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Enabling HubTransport Components..." -MessageColor Yellow -ProgressState "Enabling HubTransport..." -ProgressPercent 60
            $outStep3=Set-EMMHubTransportState -Servername $PSBoundParameters['ServerInMaintenance'] -Status Active
            AddEmptylines -numberoflines 2 -MessageToIncludeAtTheEnd "Enabling Exchange Server Components..." -MessageColor Yellow -ProgressState "All should be done, below are the result, Make sure that there is no failure or other issues" -ProgressPercent 90
              Write-Host "-------- Result for Activating Server " -NoNewline ;Write-Host "$($PSBoundParameters['ServerInMaintenance']) " -ForegroundColor Yellow -NoNewline ;Write-Host " -----------"
              $ExOutMainProgress.Add("ServerWide",(Get-ServerComponentState $PSBoundParameters['ServerInMaintenance'] -Component ServerWideOffline).State)
              $ExOutMainProgress.Add("ClusterNode",$outstep1)
              $ExOutMainProgress.Add("DB Server Activation",$outStep2)
              $ExOutMainProgress.Add("HubTransport",$outStep3)
        }
        
        End{
       return $ExOutMainProgress | Format-Table -AutoSize -Wrap
        }
}
Export-ModuleMember Stop-EMMDAGEnabled


Function Set-EMMHubTransportState {
[CmdletBinding()]
Param(
[parameter(mandatory=$true,ValueFromPipeline=$true,Position=0)]$Servername,
[validateset("Draining","Active")]$Status

)

  Process{
  Write-Host "Configuring Hub Transport to be " -NoNewline; Write-Host "$($PSBoundParameters['Status'])" -ForegroundColor Green -NoNewline ; Write-Host " For " -NoNewline; Write-Host "$($PSBoundParameters['Servername'])" -ForegroundColor Green

    Try
    {    

      if (@((Get-ExchangeServer | Get-ServerComponentState -Component Hubtransport | Where-Object {($_.State -like "Active")  -and  ($_.Serverfqdn -notlike "*$Servername*")}).state).Count -eq 0){
            Write-warning "Ops, there are no more servers with a HubTransport state set to Active State in the environment, Please make sure to have at least one"
            break
            }
            $TransportState=@{
            identity=$PSBoundParameters['servername']
            Component='HubTransport'
            State=$PSBoundParameters['Status']
            Requester="Maintenance"
            }
       Set-ServerComponentState @TransportState
       Start-Sleep -Seconds 2
       $Srvcomstate=(Get-ServerComponentState $PSBoundParameters['servername'] -Component HubTransport).state
       return $Srvcomstate
      
    }
    catch {
        Write-Warning -Message $Error[0]
        break
    }

    }

    End{
       Write-Host "Configs are completed, Now $($PSBoundParameters['servername']) is set to be :" -NoNewline; write-host (Get-ServerComponentState $PSBoundParameters['servername'] -Component HubTransport).state -ForegroundColor Green

    }
    

    
}

Function Start-EMMRedirectMessage{
param(
[parameter(mandatory=$True,ValueFromPipeline=$true,Position=0)]$SourceServer,
[parameter(mandatory=$True)][ValidatePattern("(?=^.{1,254}$)(^(?:(?!\d+\.|-)[a-zA-Z0-9_\-]{1,63}(?<!-)\.?)+(?:[a-zA-Z]{2,})$)")][string]$ToServer
)
        $counter=0
   Write-Host "Redirecting the Queue, Minimum waiting time is 15 seconds..."
             Redirect-Message -Server $PSBoundParameters['SourceServer'] -Target $PSBoundParameters['ToServer'] -Confirm:$False -ErrorAction Stop
             Start-Sleep -Seconds 10
             Write-Host "Queue redirection completed..."
             do
             {
               Write-Host "."   -NoNewline
               $QL=(Get-Queue -server $PSBoundParameters['SourceServer'] | Where-Object {($_.DeliveryType -notlike "Shadow*") -and ($_.DeliveryType -notlike "Undefined") }| Select-Object Messagecount | Measure-Object -Sum -Property MessageCount).Sum
               if ($ql -eq 0){return "Queue Transfer successfully"}
               Start-Sleep -Seconds 1
               $counter++
               if ($counter -eq 60){
                Write-Host "Queue Transfer was not completed"
                Write-Host "The Number of remaining Queue is" $($QL)
                $YesNo=Read-Host "Press Y to continue or any other key to abort the process"
                    if ($YesNo -like "Y"){return "Queue Transfer is not completed, But the user accepted it"}
                    else{
                    Throw "User Aborted Queue Transfar.."
                    }
                }
             }
             while ($ql -gt 0)

        }

Function Set-EMMClusterConfig {
Param(
[parameter(mandatory=$true,ValueFromPipeline=$true,Position=0)]$ClusterNode,
[parameter(mandatory=$true)][validateset("PauseThisNode","ResumeThisNode")]$PauseOrResume
)

    Process{
        Write-Host "Starting Cluster Management for "-NoNewline ; Write-Host $PSBoundParameters['ClusterNode'] -ForegroundColor Yellow
    try{
          
          Write-Host "Checking Cluster Readiness and resilience" -ForegroundColor Yellow
          $Status=Get-ClusterNode -Cluster (Get-DatabaseAvailabilityGroup) -ErrorAction Stop
          Write-Host "The number of Up Nodes are $(@(($Status | Where-Object {$_.state -like 'up'}).State).count)" -ForegroundColor  Yellow

        if ($PSBoundParameters['PauseOrResume'] -like "PauseThisNode"){
                
         
            if (@($Status | Where-Object {($_.state -like 'up') -and ($_.name -notlike $PSBoundParameters['ClusterNode'])}).count -eq 0){
                Write-Host "WARNING: The number of available clusters is not enough, Please stop and resume one node at least" -ForegroundColor Red
                $Status | Select-Object Name,State,Cluster
                break
                }

            if (($Status | Where-Object{$_.name -like $PSBoundParameters['ClusterNode']}).State -Like "Paused"){
                Write-Host "The node is already disabled...Nothing to do in this step"
                return "Node is Already Paused"
            }
             $clsstate=Suspend-ClusterNode -Name $PSBoundParameters['ClusterNode'] -Cluster (Get-DatabaseAvailabilityGroup) -ErrorAction Stop
                Start-Sleep -Seconds 2
                return $clsstate.State
               }
               ## Resume Cluster node
         if ($PSBoundParameters['PauseOrResume'] -like "ResumeThisNode"){
          if (($Status | Where-Object{$_.name -like $PSBoundParameters['ClusterNode']}).State -Like "Up"){
                Write-Host "Node already Up...Nothing to do in this step"
                return "Node is Already Up"
            }
                $clsresumestate=Resume-ClusterNode -Name $PSBoundParameters['ClusterNode'] -Cluster (Get-DatabaseAvailabilityGroup) -ErrorAction Stop
                Start-Sleep -Seconds 2
                return $clsresumestate.State
             }
                

    }
    Catch {
    Write-host $Error[0].Exception -ForegroundColor Red
    Write-Host "Failed to prepare the cluster, Please check if the computer name is correct and if the computer still reachable or went offline... Aborting"
    break
    }
}
End{
Write-Host "Cluster Management is completed..."
    }
}


Function Set-EMMDBActivationMoveNow{
    [cmdletbinding()]
    Param(
    [parameter(Mandatory=$true,
                 ValueFromPipeline=$true,
                 Position=0)]
                 $ServerName,
    [parameter(mandatory=$True)][validateset("IntrasiteOnly","Unrestricted","BlockMode")]$ActivationMode,
    [parameter(mandatory=$false)]$TimeoutBeforeManualMove=120,
    [parameter(mandatory=$false)][switch]$SkipValidation
    
    )

    begin{
    $FinalResult=""
    }
    Process{
        Try{
            ##Validation first
            $DBSetting=Get-MailboxServer
            if (@($DBSetting | Where-Object {($_.DatabaseCopyAutoActivationPolicy -notlike "Blocked") -and ($_.name -notlike $PSBoundParameters['ServerName'])}).count -eq 0){
                Write-Warning "There is no available server with an Activation Policy set to Unrestricted or IntrasiteOnly" 
                Write-Warning "Please ensure that there is at least one server available to handle the load..."
                $DBSetting
                break
                }
                
                if (($PSBoundParameters['ActivationMode'] -like "BlockMode")){
                    Set-MailboxServer $PSBoundParameters['ServerName'] -DatabaseCopyActivationDisabledAndMoveNow $true -ErrorAction stop
                    Start-Sleep 1
                    $DatabaseCopyPolicy=Get-MailboxServer $PSBoundParameters['ServerName'] -ErrorAction Stop 
                    Write-Host "Please write down the current Activation policy as it might be needed later" 
                    write-host $DatabaseCopyPolicy.DatabaseCopyAutoActivationPolicy -ForegroundColor DarkRed -BackgroundColor Yellow
                    Set-MailboxServer $PSBoundParameters['ServerName'] -DatabaseCopyAutoActivationPolicy Blocked  -ErrorAction Stop

                    if (@(Get-MailboxDatabaseCopyStatus -Server $PSBoundParameters['ServerName'] | Where-Object{$_.Status -eq "Mounted"}).count -eq 0){
                    Write-Host "No Active Database on this server was found... The New DatabaseCopyAutoActivationPolicy is: " -NoNewline 
                    Write-Host (Get-MailboxServer $PSBoundParameters['ServerName']).DatabaseCopyAutoActivationPolicy -ForegroundColor Green 
                    return "No Active Database, Server is ready"
                    }
                    try{
                            Write-Host "Waiting for Database migration to complete, Timeout for this process is $($PSBoundParameters['TimeoutBeforeManualMove']) Seconds"
                            Write-Host "Exchange will make a basic health and validate other database, this might take sometime..."
                            $i=0
                            Write-Host "EMMEXDAGModule v2 note: Database migration will follow database activation preference instead of moving all databases to a single server." -ForegroundColor Yellow
                            Write-host "Manual migration will start and move all DBs from $($PSBoundParameters['ServerName'])"
                            Write-Host "ReplayQueue Length and Copy Queue length should be zero, if not the script will wait untill all transaction are completed."
                            Do{
                                Write-Host "." -NoNewline
                                $i++
                                Start-Sleep 1
                                    if ($i -ge $PSBoundParameters['TimeoutBeforeManualMove']){
                                        $DBOnServer=Get-MailboxDatabaseCopyStatus -Server $PSBoundParameters['ServerName'] -ErrorAction stop| Where-Object{$_.Status -eq "Mounted"}
                                          foreach ($singleDB in $DBOnServer){ # Checking Queue length 
                                            Write-Host "Processing" $($singleDB).DatabaseName -ForegroundColor Green 
                                                $DBOnRemoteServerQL=Get-MailboxDatabase $singleDB.DatabaseName | Get-MailboxDatabaseCopyStatus -ErrorAction Stop | Where-Object {($_.databasename -like $singleDB.DatabaseName) -and ($_.MailboxServer -notlike $PSBoundParameters['ServerName'])}
                                                $TotalQueueLength =$(($DBOnRemoteServerQL.copyQueuelength | Measure-Object -Sum).Sum) +$(($DBOnRemoteServerQL.ReplayQueueLength | Measure-Object -Sum).Sum)
                                                    if ($TotalQueueLength -gt 0){
                                                        Write-Host "Some pending Logs are waiting for replay, I will wait till the process is finished"
                                                            do{
                                                                Write-Host "." -NoNewline
                                                                $DBOnRemoteServerQL=Get-MailboxDatabase $singleDB.DatabaseName | Get-MailboxDatabaseCopyStatus -ErrorAction Stop | Where-Object {($_.databasename -like $singleDB.DatabaseName) -and ($_.MailboxServer -notlike $PSBoundParameters['ServerName'])}
                                                                Start-Sleep 1
                                                              }
                                                              While (
                                                              
                                                              $(($DBOnRemoteServerQL.copyQueuelength | Measure-Object -Sum).Sum) +$(($DBOnRemoteServerQL.ReplayQueueLength | Measure-Object -Sum).Sum) -ne 0
                                                              )
    
    
                                                    }
                                                    Else{
                                                        switch($PSBoundParameters.ContainsKey('SkipValidation')){
    
                                                        $true {Move-ActiveMailboxDatabase -Identity $singleDB.DatabaseName -Confirm:$false -ErrorAction Stop -SkipClientExperienceChecks -SkipCpuChecks -SkipMaximumActiveDatabasesChecks -MoveComment "EMM Module"  -SkipMoveSuppressionChecks 
                                                                }
                                                        $false {Move-ActiveMailboxDatabase -Identity $singleDB.DatabaseName -Confirm:$false -ErrorAction Stop 
                                                                }
                                                        }
                                                        Write-Host "Database $($singleDB.DatabaseName) is now hosted on " -NoNewline 
                                                        Write-Host $(Get-MailboxDatabase | Get-MailboxDatabaseCopyStatus | Where-Object {($_.databasename -like $singleDB.DatabaseName) -and ($_.status -like "mounted")}).MailboxServer -ForegroundColor Green
                                                        Start-Sleep -Seconds 1
                                                    }
                                                }                                  
    
    
                                        }
    
                            }
                            while(
                                @(Get-MailboxDatabaseCopyStatus -Server $PSBoundParameters['ServerName']  -ErrorAction Stop | Where-Object{$_.Status -eq "Mounted"}).count -ne 0
                            )
                            
                        }
    
                        Catch [Microsoft.Exchange.Cluster.Replay.AmDbActionWrapperException]{
                        Write-Host "It seems that there still more logs to be shipped, please check the error below and try to re-run the commands after sometime" -ForegroundColor Yellow
                        Write-Host "Or the database has been already activated on the remote server."
                        Write-Host $_.exception.message
                        return "Require review, Please Run Get-MailboxDatabaseCopyStatus and also run the Test-EMMReadiness cmdlet to confirm the readiness"
                        }
                        catch [Microsoft.Exchange.Cluster.Replay.AmDbMoveMoveSuppressedException]{
                        Write-Host "`nIt seems that there are multiple move request for this database" -ForegroundColor Red
                        Write-Host $_.exception.message -ForegroundColor Red
                        Write-Host "To ignore the error and move the database, use the following paramter " -NoNewline -ForegroundColor white
                        Write-Host "-SkipValidation" -ForegroundColor Green
                        }
                        catch{
                        Write-Warning $_.Exception.Message
                        break
                        }
          
                }
                Else{
                Write-Host "Leaving Block Mode"
                
                try{
    
                    Set-MailboxServer $PSBoundParameters['ServerName'] -DatabaseCopyAutoActivationPolicy $PSBoundParameters['ActivationMode']  -ErrorAction Stop
                    Set-MailboxServer $PSBoundParameters['ServerName'] -DatabaseCopyActivationDisabledAndMoveNow $false  -ErrorAction Stop
                    Start-Sleep 1
                    $FinalResult= (Get-MailboxServer $PSBoundParameters['ServerName']  -ErrorAction Stop) 
                    return $FinalResult.DatabaseCopyAutoActivationPolicy
                    }
                    catch{
                    Write-Host $Error[0]
                    break
                    }
    
                }
    
    
        }
        Catch{
        Write-Host "Failure in Set-EMMDBActivationMoveNow"
        Write-Host $Error[0]
        break
    
        }
    }
        End{
            Write-Host "Activation configuration is completed..."
            }
    }



Function Test-EMMReadiness{
param(
[parameter(mandatory=$True,ValueFromPipeline=$true,Position=0)]$SourceServer,
[parameter(Mandatory=$false)][switch]$IgnoreCluster
)

   Process{
   Write-Host "This process will check the server readiness"
   Write-Host "There will be no move or any change to the environment, just a check"
   
    Test-Connection -ComputerName $PSBoundParameters['SourceServer'] -ErrorAction stop -Count 1
       AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Testing Exchange Ports reachability, Checking Port 80..." -MessageColor White
        (Get-ExchangeServer).foreach{$Port80Test=Test-NetConnection -ComputerName $_.name -Port 80
            if ($Port80Test.TcpTestSucceeded -like $True){
                Write-Host $($_.name) -ForegroundColor Green -NoNewline;Write-Host " is reachable on Port 80"
                    }
            Else{
                Write-Host $($_.name) -ForegroundColor Red -NoNewline;Write-Host " is NOT reachable on Port 80"
                }
                                    }
        
        AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Testing Exchange Ports reachability, Checking Port 443..." -MessageColor White
        (Get-ExchangeServer).foreach{$Port443Test=Test-NetConnection -ComputerName $_.name -Port 443
            if ($Port443Test.TcpTestSucceeded -like $True){
                Write-Host $($_.name) -ForegroundColor Green -NoNewline;Write-Host " is reachable on Port 443"
                    }
            Else{
                Write-Host $($_.name) -ForegroundColor Red -NoNewline;Write-Host " is NOT reachable on Port 443"
                }
                                    }       

            AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Checking HubTransport Server Component" -MessageColor White
            $ServerComp=Get-ExchangeServer | Get-ServerComponentState -Component Hubtransport
       if (!($ServerComp | Where-Object {($_.State -like "Active")  -and  ($_.Serverfqdn -notlike "*($PSBoundParameters['SourceServer'])*")})){
            Write-host "You Don't have any additional Node with a Hubtransport State set to Active" -ForegroundColor Red
            Get-ExchangeServer | Get-ServerComponentState -Component Hubtransport
            }
            Else{
              $ServerComp.foreach{
                   if ($_.state -like "Active"){Write-Host "The HubTransport State of $($_.ServerFqdn) is: " -NoNewline; Write-Host "Active" -ForegroundColor Green}
                    Else{
                    Write-Host "The HubTransport State of $($_.ServerFqdn) is: " -NoNewline; Write-Host $_.State -ForegroundColor RED}
                    }
            }

            AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Checking ServerWideOffline Server Component" -MessageColor White
           $ServerCompSWO=Get-ExchangeServer | Get-ServerComponentState -Component ServerWideOffline
       if (!($ServerCompSWO | Where-Object {($_.State -like "Active")  -and  ($_.Serverfqdn -notlike "*($PSBoundParameters['SourceServer'])*")})){
            Write-host "You Don't have any additional Node with a ServerWideOffline State set to Active" -ForegroundColor Red
            Get-ExchangeServer | Get-ServerComponentState -Component ServerWideOffline
            }
            Else{
              $ServerCompSWO.foreach{
                   if ($_.state -like "Active"){Write-Host "The ServerWideOffline State of $($_.ServerFqdn) is: " -NoNewline; Write-Host "Active" -ForegroundColor Green}
                    Else{
                    Write-Host "The ServerWideOffline State of $($_.ServerFqdn) is: " -NoNewline; Write-Host $_.State -ForegroundColor RED}
                    }
            }

                   AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Checking HighAvailability Server Component" -MessageColor White
           $ServerCompHA=Get-ExchangeServer | Get-ServerComponentState -Component HighAvailability
       if (!($ServerCompHA | Where-Object {($_.State -like "Active")  -and  ($_.Serverfqdn -notlike "*($PSBoundParameters['SourceServer'])*")})){
            Write-host "You Don't have any additional Node with a HighAvailability State set to Active" -ForegroundColor Red
            Get-ExchangeServer | Get-ServerComponentState -Component HighAvailability
            }
            Else{
              $ServerCompHA.foreach{
                   if ($_.state -like "Active"){Write-Host "The HighAvailability State of $($_.ServerFqdn) is: " -NoNewline; Write-Host "Active" -ForegroundColor Green}
                    Else{
                    Write-Host "The HighAvailability State of $($_.ServerFqdn) is: " -NoNewline; Write-Host $_.State -ForegroundColor RED}
                    }
            }
            switch ($PSBoundParameters.ContainsKey('IgnoreCluster')){
            $true {Write-Host "Skipping Cluster check..." -ForegroundColor Yellow }
            $false {Write-Host "Starting Cluster Check..." -ForegroundColor Yellow}
            }

        if (!($PSBoundParameters.ContainsKey('IgnoreCluster'))){
          $Status=Get-Cluster (Get-DatabaseAvailabilityGroup)| Get-ClusterNode
          if (!($Status | Where-Object {($_.state -like 'up') -and ($_.name -notlike $PSBoundParameters['SourceServer'])})){
                Write-Host "WARNING: The number of available clusters is not enough, Please stop and resume one node at least" -ForegroundColor Red
                $Status
                }
                Else{
                Write-Host "Active Cluster Nodes are: " -NoNewline ;Write-Host $($Status | Where-Object {$_.state -like "Up"}).count -ForegroundColor Green
                Write-Host "Unstable Cluster Nodes are: " -NoNewline
                $NotUpCluster=@($Status | Where-Object {$_.state -notlike "Up"}).count
                    switch ($NotUpCluster)
                    {
                        '0' {Write-Host "0" -ForegroundColor Green}
                        {$_ -gt 0} {Write-Host $($Status | Where-Object {$_.state -notlike "Up"}).count -ForegroundColor Red}
                        
                    }
                 
                $Status | Where-Object {$_.state -notlike "Up"}
                }
           }
                 AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Checking Exchange Servers for Mounting policy" -MessageColor White
        $DBSetting=Get-MailboxServer
        if (!($DBSetting | Where-Object {($_.DatabaseCopyAutoActivationPolicy -notlike "Blocked") -and ($_.name -notlike $PSBoundParameters['SourceServer'])})){
            Write-Warning "There is no available server with an Mounting Policy set to Unrestricted or IntrasiteOnly"  
            Write-Warning "Please ensure that there is at least one server available to handle the load..."
            $DBSetting | Select-Object name,DatabaseCopyAutoActivationPolicy,DatabaseCopyActivationDisabledAndMoveNow
            }
            Else{
                $DBSetting.ForEach{
                    if ($_.DatabaseCopyAutoActivationPolicy -like "Unrestricted"){Write-Host "Mounting Policy for $($_.Name) is: "-NoNewline; Write-Host "Unrestricted" -ForegroundColor Green} 
                    if ($_.DatabaseCopyAutoActivationPolicy -Like "IntrasiteOnly"){Write-Host "Mounting Policy for $($_.Name) is: "-NoNewline; Write-Host "IntrasiteOnly" -ForegroundColor Yellow}
                    if ($_.DatabaseCopyAutoActivationPolicy -Like "Blocked"){Write-Host "Mounting Policy for $($_.Name) is: "-NoNewline; Write-Host "Blocked" -ForegroundColor Red}
                }
            }

               AddEmptylines -numberoflines 1 -MessageToIncludeAtTheEnd "Checking Exchange Servers for Activating Policy" -MessageColor White
        if (@($DBSetting | Where-Object {($_.DatabaseCopyActivationDisabledAndMoveNow -notlike $true) -and ($_.name -notlike $PSBoundParameters['SourceServer'])}).count -eq 0){
            Write-Warning "There is no available server with an Activation Policy set to Unrestricted or IntrasiteOnly" 
            Write-Warning "Please ensure that there is at least one server available to handle the load..."
            $DBSetting | Select-Object name,DatabaseCopyAutoActivationPolicy,DatabaseCopyActivationDisabledAndMoveNow
            }
            Else{
                $DBSetting.ForEach{
                    if ($_.DatabaseCopyActivationDisabledAndMoveNow -like $False){Write-Host "Activation Policy for $($_.Name) is: "-NoNewline; Write-Host "Can host DB" -ForegroundColor Green} 
                    if ($_.DatabaseCopyActivationDisabledAndMoveNow -Like $true){Write-Host "Activation Policy for $($_.Name) is: "-NoNewline; Write-Host "Not Recommended, True for DatabaseCopyActivationDisabledAndMoveNow" -ForegroundColor red}
                  }
            }
            
         Write-Host "Checking Servicelth:`n"
        
        $EXServers=get-exchangeserver
        foreach($singleExServer in $EXServers){
            $ServiceNotRunning=Test-ServiceHealth -Server $singleExServer
            $ServiceNotRunning.ForEach{
                if ($_.ServicesNotRunning.count -gt 0){
                    write-host $singleExServer "has " -NoNewline
                    write-host $_.ServicesNotRunning.count -NoNewline -ForegroundColor Red
                    Write-Host " of failed Service:" -NoNewline
                    Write-Host $_.ServicesNotRunning -ForegroundColor Green
                    }
                    Else{
                    write-host $singleExServer $_.Role "is OK" 
                    }
            
                }
            }

       
        Write-Host "Checking Log size, make sure that there is no log queue or copy queue"
        (get-ExchangeServer).foreach{ Get-MailboxDatabaseCopyStatus -Server $_.name | Format-Table Name,Status,ContentIndexState,CopyQueueLength,ReplayQueueLength}
        Write-Host "Testing Replication Health"
        get-exchangeserver | Test-ReplicationHealth | Format-Table -AutoSize


    }
    End{
    Write-Host "Process is completed.."
    }

}
Export-ModuleMember Test-EMMReadiness

Write-Host "***************************************************************" -ForegroundColor White
Write-Host "Welcome to EMM (Exchange Maintenance Module)" -ForegroundColor Green -NoNewline
Write-Host " V2" -ForegroundColor Yellow
Write-Host "***************************************************************" -ForegroundColor White
Write-Host "Please Give me a moment to load Exchange Snapin...." -ForegroundColor Green
Write-Host "One more tip: Run this Module using RunAsAdministrator " -ForegroundColor Green
Write-Host "If you unload the EmmExDAGModule Module using Remove-Module cmdlet, you need to close the PowerShell Window and start it again" -ForegroundColor Yellow
Write-Host "This is due to an issue with Microsoft Snapin." -ForegroundColor Yellow
Write-Host "If you have any issue or idea request, please feel free and post it as an Issue on my GitHub or keep it a comment on the Module home page"
Write-Host "https://github.com/farismalaeb/Powershell/issues" -ForegroundColor Blue -BackgroundColor White

try{
    if ((Get-PSSnapin).Name -notcontains 'microsoft.exchange.management.powershell.snapin'){
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue
       }
 }
catch{
Write-Warning "Ops, something went wrong, are you sure you have Exchange Powershell Snapin installed ?!`n"
$_.exception.message
}
