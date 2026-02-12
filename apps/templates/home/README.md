# Home Page Application Switcher

This directory contains the Kubernetes manifests for the home page application that provides a unified interface to switch between Docs and Matrix applications.

## Overview

The home page application creates a persistent navigation bar at the top of the browser window with two buttons:
- **📚 Docs** - Switches to the LaSuite Docs application
- **💬 Matrix** - Switches to the Element Matrix client

Both applications are embedded as iframes, allowing users to switch between them without losing their session state.

## Features

- **Persistent Navigation**: The navigation bar stays visible at all times
- **Lazy Loading**: The Matrix iframe only loads when first accessed
- **Mobile Responsive**: Optimized for mobile devices
- **Keyboard Shortcuts**: 
  - `Ctrl+1` - Switch to Docs
  - `Ctrl+2` - Switch to Matrix
- **Modern UI**: Clean, gradient design with smooth transitions

## Files

- `namespace.yaml` - Creates the `home` namespace
- `configmap.yaml` - Contains the HTML/CSS/JS for the switcher interface
- `nginx-config.yaml` - NGINX configuration for serving static content
- `deployment.yaml` - Kubernetes deployment with NGINX container
- `service.yaml` - ClusterIP service to expose the deployment
- `ingress.yaml` - Ingress with TLS certificate for `home.example.com`

## Deployment

### Prerequisites

1. DNS record for `home.example.com` must be created (handled by Terraform)
2. Both `docs.example.com` and `matrix.example.com` must be accessible
3. Ingress annotations must be applied to allow iframe embedding

### Deploy

```bash
# From the apps directory
./deploy-home.sh
```

### Manual Deployment

```bash
# Apply all manifests
kubectl apply -f templates/home/namespace.yaml
kubectl apply -f templates/home/configmap.yaml
kubectl apply -f templates/home/nginx-config.yaml
kubectl apply -f templates/home/deployment.yaml
kubectl apply -f templates/home/service.yaml
kubectl apply -f templates/home/ingress.yaml
```

## Configuration

### Iframe Embedding

The application requires that both Docs and Matrix applications allow iframe embedding. This is configured via NGINX ingress annotations:

```yaml
nginx.ingress.kubernetes.io/configuration-snippet: |
  more_set_headers "X-Frame-Options: ALLOWALL";
  more_set_headers "Content-Security-Policy: frame-ancestors 'self' https://home.example.com";
```

### DNS Configuration

The DNS record for `home.example.com` is automatically created by the Terraform DNS module in `modules/dns/main.tf`.

## Troubleshooting

### Check Deployment Status

```bash
kubectl get pods -n home
kubectl get ingress -n home
kubectl describe ingress home-page -n home
```

### View Logs

```bash
kubectl logs -f deployment/home-page -n home
```

### Test Connectivity

```bash
# Test if the service is accessible
kubectl port-forward service/home-page 8080:80 -n home
# Then visit http://localhost:8080
```

### Common Issues

1. **Iframe not loading**: Check if the target applications have proper CSP headers
2. **SSL certificate issues**: Verify cert-manager is working and the certificate is issued
3. **DNS not resolving**: Check if the DNS record was created and propagated

## Security Considerations

- The application uses HTTPS with Let's Encrypt certificates
- Security headers are configured in the NGINX configuration
- CSP headers are set to only allow framing from the home domain
- Each iframe maintains its own session isolation

## Performance

- Lazy loading reduces initial page load time
- Static content is cached for optimal performance
- Minimal resource usage (50m CPU, 64Mi memory requests)
