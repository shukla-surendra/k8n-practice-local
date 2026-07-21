```
kubectl apply -f nginx-deployment.yaml
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

## Enable ingress

```
minikube addons enable ingress
```

```
kubectl apply -f ingress.yaml
```

Add the minikube IP to /etc/hosts so the host rule resolves:

```
echo "$(minikube ip) sample-nginx.local" | sudo tee -a /etc/hosts
```

```
curl http://sample-nginx.local
```

## Cleanup

```
kubectl delete -f ingress.yaml
```

```
kubectl delete -f nginx-deployment.yaml
```