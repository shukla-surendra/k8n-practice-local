```
kubectl apply -f nginx-deploy.yaml
```

```
kubectl expose deployment nginx-deployment --type=NodePort --port=80
```

```
minikube service nginx-deployment --url
```

```
kubectl scale deployment nginx-deployment --replicas=2
```

```
kubectl describe service nginx-deployment
```

```
kubectl delete -f nginx-deployment.yaml
```