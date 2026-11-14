# Which groups each computer belongs to. Computer names are compared without regard to case.
# A group is the folder groups/<name>/: its own choco-reqs.txt (optional) and scripts/*.ps1 (optional).
@{
    # Groups of every computer (e.g. @('all'))
    Default = @()

    Computers = @{
        'OFFICE-01' = @('accounting')
        'OFFICE-02' = @('accounting')
        # 'RECEPTION' = @('reception')
    }
}
