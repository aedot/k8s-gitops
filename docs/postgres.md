- Delete an entry from gatus db if you don't want to monitor it anymore
```
kubectl exec -it <postgres-pod-name> -n <namespace> -- bash
psql -U <username> -d <database-name>
select * from endpoints;
delete from endpoints where name = 'whatever';
or
delete from endpoints where endpoint_id = '5';
```

- List all tables
```
\dt
```

- Trigger a manual backup
```
kubectl annotate cluster postgres17 -n database postgresql.cnpg.io/backup=true --overwrite
kubectl annotate cluster immich -n database postgresql.cnpg.io/backup=true --overwrite
```
