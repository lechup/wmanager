# Which groups each computer belongs to. Computer names are compared without regard to case.
# A group is the folder groups/<name>/: its own choco-reqs.txt, scripts/*.ps1 and jobs/<when>/*.ps1 (all optional).
@{
    # Groups of every computer
    Default = @('all')

    Computers = @{
        'OFFICE-01' = @('accounting')
        'OFFICE-02' = @('accounting')
        # 'RECEPTION' = @('reception')
    }
}
