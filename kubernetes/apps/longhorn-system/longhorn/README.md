# Longhorn Headache

### longhorn not starting after initial start-up
```
kubectl -n longhorn-system patch nodes.longhorn.io <node> \
  --type merge -p '{"spec":{"disks":{"default-disk-1":{"path":"/var/mnt/longhorn","allowScheduling":true,"storageReserved":0}}}}'
```

### delete any old data on disk
```
kubectl run disk-wiper -n longhorn-system --restart=Never --rm -it \
  --image=busybox \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "wiper",
        "image": "busybox",
        "command": ["sh", "-c", "rm -rf /data/* && echo Disk Cleaned"],
        "volumeMounts": [{
          "name": "host-storage",
          "mountPath": "/data"
        }]
      }],
      "volumes": [{
        "name": "host-storage",
        "hostPath": {
          "path": "/var/mnt/longhorn"
        }
      }],
      "nodeName": <node>
    }
  }'
```
