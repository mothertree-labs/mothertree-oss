# Element Web Customization

## Theming

Element Web supports theming via the `config.setting_defaults.custom_themes` configuration in `apps/values/element.yaml`.

### Supported Theme Variables

Element supports limited color variables:
- `accent-color`, `primary-color`
- `sidebar-color`, `roomlist-background-color`, `roomlist-text-color`
- `timeline-background-color`, `timeline-text-color`
- And more in the `colors` section

### Compound Tokens

For Element v1.4+ (using compound tokens):
```yaml
compound:
  --cpd-color-border-interactive: "var(--cpd-color-green-700)"
  --cpd-color-bg-action-selected: "var(--cpd-color-green-200)"
  --cpd-color-text-action-accent: "var(--cpd-color-green-700)"
```

## Custom CSS

For styling that isn't exposed via theme variables (e.g., `.mx_TabbedView_tabLabel_active`), custom CSS can be injected at runtime.

### How It Works

1. **CSS file location**: `apps/themes/element/custom.css`
2. **ConfigMap**: Added to `element-branding` ConfigMap via `scripts/create_env`
3. **Volume mount**: Mounted in the Element container at `/app/themes/custom.css`
4. **Injection**: The ingress uses nginx `sub_filter` to inject a `<link>` tag into all HTML responses

### Ingress Configuration

In `apps/manifests/element/element-static-cache-ingress.yaml.tpl`:

```yaml
nginx.ingress.kubernetes.io/server-snippet: |
  sub_filter_types text/html;
  sub_filter '</head>' '<link rel="stylesheet" href="/themes/custom.css"></head>';
  sub_filter_once true;
```

### Why nginx sub_filter?

The `ananace/element-web` Helm chart doesn't support custom CSS files natively. The nginx sub_filter is a workaround to inject custom styles at the gateway level.

## Files

- `apps/values/element.yaml` - Base Element configuration and theming
- `apps/manifests/element/element-static-cache-ingress.yaml.tpl` - Ingress with CSS injection
- `scripts/create_env` - Creates the branding ConfigMap with custom CSS
- `apps/themes/element/custom.css` - Custom CSS overrides
