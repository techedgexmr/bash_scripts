cat > disksetup-config.yaml << EOF
DiskSetup:
  TargetDisk: /dev/nvme1n1  # Adjust based on your additional volume
  VgName: vg_stig
  LvSwap:
    Size: 8G
  LvOpt:
    Size: 10G
  LvHome:
    Size: 10G 
  LvTmp:
    Size: 10G
  LvVar:
    Size: 10G
  LvVarLog:
    Size: 10G
  LvVarLogAudit:
    Size: 10G
EOF
