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

## PCS resource group

This role adds the Samba resource to an existing PCS resource group
(default: `group-nas`). The group provides implicit colocation and start
ordering — resources within a group always run on the same node and start
in the order they were added. This is simpler than explicit colocation and
ordering constraints and matches the existing pattern for VIP (`nas-ip`) and
ZFS resources.

> **Note:** iSCSI resources are intentionally kept outside `group-nas` with
> separate constraints to avoid a known democratic-csi cascading restart bug.
> Samba does not trigger this bug because it is not managed by democratic-csi.

When `nas_samba_pcs_enabled` is true, the systemd `smb` service is disabled —
PCS is the sole owner of the Samba lifecycle.
