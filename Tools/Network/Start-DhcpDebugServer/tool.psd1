@{
    Name          = 'DHCP Debug Server'
    Description   = 'Minimal DHCP server for debugging: hands out addresses from a pool on one adapter, e.g. to a device connected directly to the PC. Never run it on a production network.'
    Command       = 'Start-DhcpDebugServer'
    Order         = 20
    RequiresAdmin = $false
    Version       = '0.1.0'
}
