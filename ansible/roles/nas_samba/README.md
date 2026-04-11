# nas_samba

Ansible role for managing Samba (SMB/CIFS) on Rocky Linux NAS nodes with
Pacemaker/PCS high-availability support.

Designed for active/passive HA clusters where PCS manages Samba lifecycle
alongside ZFS and VIP resources. Samba is added to the existing `group-nas`
resource group, which provides implicit colocation and ordering.

## Variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `nas_samba_packages` | `[samba, samba-common]` | Packages to install |
| `nas_samba_min_protocol` | `SMB3` | Minimum SMB protocol version |
| `nas_samba_max_protocol` | `SMB3_11` | Maximum SMB protocol version |
| `nas_samba_encrypt` | `required` | SMB encryption setting |
| `nas_samba_server_signing` | `mandatory` | Server message signing |
| `nas_samba_client_signing` | `mandatory` | Client message signing |
| `nas_samba_disable_netbios` | `true` | Disable legacy NetBIOS |
| `nas_samba_workgroup` | `HOMELAB` | Workgroup name |
| `nas_samba_fruit_enabled` | `true` | Enable macOS vfs_fruit optimizations |
| `nas_samba_fruit_model` | `Xserve` | Finder server icon model |
| `nas_samba_fruit_metadata` | `stream` | How to store macOS metadata |
| `nas_samba_fruit_nfs_aces` | `no` | Prevent macOS from modifying UNIX perms via NFS ACEs |
| `nas_samba_shares` | `[]` | List of share definitions (see below) |
| `nas_samba_users` | `[]` | List of Samba users (passwords from SOPS-encrypted vars) |
| `nas_samba_pcs_enabled` | `true` | Whether PCS manages Samba |
| `nas_samba_pcs_resource_name` | `smb-service` | PCS resource name |
| `nas_samba_pcs_group` | `group-nas` | PCS resource group to add Samba to |
| `nas_samba_pcs_monitor_interval` | `30s` | PCS health check interval |
| `nas_samba_pcs_start_timeout` | `30s` | PCS start timeout |
| `nas_samba_pcs_stop_timeout` | `30s` | PCS stop timeout |

## Share definition

```yaml
nas_samba_shares:
  - name: media
    path: /tank/media
    valid_users: "@media"
    writable: true
    browseable: true
    create_mask: "0664"
    directory_mask: "0775"
```

## User definition

Passwords **must** come from Ansible Vault variables:

```yaml
nas_samba_users:
  - name: editor                                    # New dedicated SMB user
    password: "{{ vault_samba_editor_password }}"
    create_system_user: true
  - name: michel                                    # Existing Linux user
    password: "{{ vault_samba_michel_password }}"
    create_system_user: false
```

When `create_system_user` is omitted it defaults to `true` (backward compatible).
Set it to `false` for users that already exist on the host to avoid changing
their shell or other properties.

## Example playbook

```yaml
- hosts: nas
  become: true
  roles:
    - role: nas_samba
      vars:
        nas_samba_shares:
          - name: media
            path: /tank/media
            valid_users: "@media"
            writable: true
        nas_samba_users:
          - name: editor
            password: "{{ vault_samba_editor_password }}"
            create_system_user: true
        nas_samba_pcs_group: group-nas
```

## PCS integration

This role manages Samba as a standalone PCS resource with **colocation and
ordering constraints** against `group-nas` (rather than group membership).
This isolates Samba failures from the ZFS/VIP/iSCSI stack — a transient
Samba restart won't cascade to other resources.

When `nas_samba_pcs_enabled` is true, the systemd `smb` service is disabled —
PCS is the sole owner of the Samba lifecycle.

## File permissions (POSIX ACLs)

ZFS datasets shared via both NFS and SMB typically have mixed ownership
(`nobody:users` from NFS, `root:root` from root-squash-disabled clients).
Instead of changing base ownership (which would break NFS), use POSIX ACLs
to grant the SMB user write access as an additive overlay.

Prerequisites: ZFS `acltype=posix` (check with `zfs get acltype <dataset>`).

```bash
# Grant user rw on existing files/dirs (X = execute on dirs only)
setfacl -R -m u:<samba_user>:rwX /path/to/share

# Default ACL — new files/dirs inherit the grant automatically
setfacl -R -d -m u:<samba_user>:rwX /path/to/share

# Verify
getfacl /path/to/share
```

This approach:

- Leaves base ownership intact (NFS apps unaffected)
- Grants SMB write access through ACL, not `force user`
- Default ACLs ensure new files from any source remain accessible
- Works with `fruit:nfs_aces = no` (which prevents macOS from mangling perms)
