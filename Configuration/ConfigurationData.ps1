﻿param (
    #Host DSC Resources
    [Parameter(Mandatory)]
    [string]$ResourcePath,
    [Parameter(Mandatory)]
    [string]$SourceVHDPath,
    [Parameter(Mandatory)]
    [String]$DeploymentPath,
    [String]$NodeChildPath      = "Nodes",
    [String]$HyperVHost         = "localhost",
    [string]$NewDomainName      = "dev.rusthawk.net",
    [String]$CredPath,
    [string]$PullCertThumbprint     = "AllowUnencryptedTraffic"
)

$DSCxWebService      = (Get-DSCResource -Name xDSCWebService).Module.ModuleBase

##
#ResourcePath - Where any ancilliary resource files will be located for copying to nodes
#SourceVHDPath - The source VHD(x) file to generate VM's from
#DeploymentPath - Where we will be storing VM's and VHD files on the Hyper-V Host
##

#For ease of use using string formatting -f
$ResourcePath += "\{0}"

if(-not $CredPath) {
    $CredPath = $ResourcePath
}

$BaseVHDPath = $ResourcePath -f 'basevhd.vhdx'

#Designate a Prefix for the name of the Hyper-V VMs
$VMPrefix = "DEV-"

#Generate GUIDs for Machines
$PullServerGUID = [guid]::NewGuid()
$PullNodeGUID   = [guid]::NewGuid()
$FirstDomainControllerGUID = [guid]::NewGuid()
$SecondDomainControllerGUID = [guid]::NewGuid()


$Script = Split-Path $MyInvocation.MyCommand.Path -Leaf

#VERBOSE Output - list generated GUIDs
Write-Verbose -Message "[$Script]: PullServerGUID: $PullServerGUID"
Write-Verbose -Message "[$Script]: PullNodeGUID: $PullNodeGUID"
Write-Verbose -Message "[$Script]: FDCGUID: $FirstDomainControllerGUID"
Write-Verbose -Message "[$Script]: SDCGUID: $SecondDomainControllerGUID"

#TODO: Determine if this is needed here or not
$PullServerIP   = '172.16.10.150'

Import-Module $PSScriptRoot/../DeploymentHelper.ps1

#Generate selfsigned certificate to encrypt MOF Credentials
#-Certificate is generated on the Host (Hyper-V)
#Private key is exported to pfx file (protected by -PrivateKeyCred credential) to be copied to the node
#Private key pfx needs to be imported on the node (Import-PFXCertificate) to enable decryption of MOF files encrypted using the pub key on the Hyper-V Host
#Figure out how to import the pfx as it requires a password, how to do this safely?

#$Thumbprint = New-DSCCertificate -CertName "MOFCert" -OutputPath ($ResourcePath -f '') -PrivateKeyCred (Import-Clixml -Path ($CredPath -f 'MOFCertCred.clixml'))
$Thumbprint = 'ABCD'

@{
    AllNodes = @(
        @{
            NodeName = "*"
            CertificateFile = "$ResourcePath\MOFCert.cer"
            Thumbprint = $Thumbprint
        };
        @{
            NodeName                = $PullServerGUID
            MachineName             = 'PullServer'
            Role                    = 'PullServer'
            DomainName              = $NewDomainName
            ModulePath              = "$env:ProgramFiles\WindowsPowerShell\DSCService\Modules"
            ConfigurationPath       = "$env:ProgramFiles\WindowsPowerShell\DSCService\Configuration"
            RegistrationKeyPath     = "$env:ProgramFiles\WindowsPowerShell\DSCService\registration.txt" 
            CertificateThumbprint   = $PullCertThumbprint
            PhysicalPath            = "$env:SystemDrive\inetpub\wwwroot\DSCPullServer"
            Port                    = 8080
            State                   = "Started"
            StaticIP                = $True
            IPAddress               = $PullServerIP
            AddressFamily           = 'IPv4'
            SubnetMask              = '24'
            RefreshMode             = 'Push'
        };
        @{
            NodeName                = $PullNodeGUID
            MachineName             = 'PullNode'
            Role                    = 'PullNode'
            DomainName              = $NewDomainName
            StaticIP                = $True
            IPAddress               = '172.16.10.165'
            AddressFamily           = 'IPv4'
            SubnetMask              = '24'
            RefreshMode             = 'Pull'
        };
        @{
            NodeName            = $FirstDomainControllerGUID
            MachineName         = 'FirstDomainController'
            Role                = 'FirstDomainController'
            DomainName          = $NewDomainName
            StaticIP            = $True
            IPAddress           = '172.16.1.21'
            SubnetMask          = '24'
            RefreshMode         = 'Pull'
            
            #DomainAdminCreds    = Import-CLIXML ($ResourcePath -f 'PDCCredentials.clixml') -ErrorAction SilentlyContinue
            #DomainSafeModePW    = Import-CLIXML ($ResourcePath -f 'DCSafeModeCredentials.clixml') -ErrorAction SilentlyContinue
        };
        @{
            NodeName            = $SecondDomainControllerGUID
            MachineName         = 'SecondDomainController'
            Role                = 'DomainController'
            DomainName          = $NewDomainName
            StaticIP            = $True
            IPAddress           = '172.16.1.31'
            SubnetMask          = '24'
            RefreshMode         = 'Pull'
            
            #DomainAdminCreds    = Import-CLIXML ($ResourcePath -f 'PDCCredentials.clixml') -ErrorAction SilentlyContinue
        }
        
        @{
            NodeName            = $HyperVHost
            Role                = "HyperVHost"
            ResourcePath        = $ResourcePath
            VHDParentPath       = $BaseVHDPath
            VHDGeneration       = "VHDX"
            VHDDestinationPath  = "$DeploymentPath\{0}.vhdx"
            VHDPartitionNUmber  = 4
            SwitchName          = "Red-Hawk Production"
            SwitchType          = "External"
            VMState             = "Running"
            Path                = $DeploymentPath

            DSCPullServer = @{
                MachineName     = "$($VMPrefix)DSCPullServer"
                MemorySizeVM    = 2048MB
                MACAddress      = '00155D8A54A0'
                VMGeneration    = 2
                VMFileCopy      = @(
                    @{
                        Source      = $ResourcePath -f "PullServer\$PullServerGUID.mof";
                        Destination = 'Windows\System32\Configuration\pending.mof'
                    }
                    @{
                        Source      = $ResourcePath -f "PullServer\$PullServerGUID.meta.mof";
                        Destination = 'Windows\System32\Configuration\metaconfig.mof'
                    }
                    @{
                        Source      = $ResourcePath -f 'pullserver_unattend.xml';
                        Destination = 'unattend.xml'
                    }
                    @{
                        Source      = $ResourcePath -f 'nodesetup.ps1';
                        Destination = 'Scripts\nodesetup.ps1'
                    }
                    @{
                        Source      = $ResourcePath -f 'setup.cmd';
                        Destination = 'Scripts\setup.cmd'
                    }
                    @{
                        Source      = $DSCxWebService;
                        Destination = 'Program Files\WindowsPowerShell\Modules\xPSDesiredStateConfiguration'
                    }
                    @{
                        #Copy all node mof files to pull server
                        Source      = $ResourcePath -f "$NodeChildPath\*.mof";
                        Destination = 'Program Files\WindowsPowerShell\DSCService\Configuration'                        
                    }
                    @{
                        #Copy all node mof checksums to pull server
                        Source      = $ResourcePath -f "$NodeChildPath\*.mof.checksum";
                        Destination = 'Program Files\WindowsPowerShell\DSCService\Configuration'                        
                    }
                ) 
            }
            
            DSCPullNode = @{
                MachineName     = "$($VMPrefix)DSCPullNode"
                MemorySizeVM    = 2048MB
                MACAddress      = "00155D8A54A5"
                VMGeneration    = 2
                VMFileCopy      = @(
                    @{
                        Source      = $ResourcePath -f "$NodeChildPath\pullnode.meta.mof";
                        Destination = 'Windows\System32\Configuration\metaconfig.mof'
                    }
                    @{
                        Source      = $ResourcePath -f 'pullnode_unattend.xml';
                        Destination = 'unattend.xml'
                    }
                    @{
                        Source      = $ResourcePath -f 'startlcm.ps1'
                        Destination = 'Scripts\startlcm.ps1'
                    }
                    @{
                        Source      = $ResourcePath -f 'setup.cmd'
                        Destination = 'Scripts\setup.cmd'
                    }
                )
            }
            
            FirstDomainController = @{
                MachineName     = "$($VMPrefix)FirstDomainController"
                MemorySizeVM    = 2048MB
                #MACAddress      = "00155D8A54A9"
                VMGeneration    = 2
                VMFileCopy      = @(
                    #Insert metaconfig file for Domain Controller
                )
            }
            
            SecondDomainController = @{
                MachineName     = "$($VMPrefix)SecondDomainController"
                MemorySizeVM    = 2048MB
                VMGeneration    = 2
                VMFileCopy      = @(
                    #Insert metaconfig file for Domain Controller
                    
                )
            }
        }
    );
    NonNodeData = @{
        PullServerAddress = $PullServerIP;
        PullServerPort    = '8080'    
    };
}
