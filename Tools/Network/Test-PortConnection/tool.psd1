@{
    Name          = 'Port Check'
    Description   = 'Checks whether TCP or UDP ports on a host are reachable – tells open, closed (reset / ICMP) and filtered apart. Keeps the last 20 checks.'
    Command       = 'Test-PortConnection'
    Order         = 30
    RequiresAdmin = $false
    Version       = '1.0.0'
}
