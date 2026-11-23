@{
    Name          = 'Find APIPA Device'
    Description   = 'Finds devices with a link-local address (169.254.x.x) on a network without DHCP server – ping sweep plus ARP cache, with offline vendor lookup.'
    Command       = 'Find-ApipaDevice'
    Order         = 10
    RequiresAdmin = $false
    Version       = '1.0.0'
}
