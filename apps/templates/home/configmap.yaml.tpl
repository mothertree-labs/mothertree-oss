apiVersion: v1
kind: ConfigMap
metadata:
  name: home-page-content
  namespace: ${NS_HOME:-home}
  labels:
    app.kubernetes.io/name: home
    app.kubernetes.io/part-of: ${TENANT_NAME}
data:
  index.html: |
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>${TENANT_DISPLAY_NAME} - Home</title>
        <style>
            * {
                margin: 0;
                padding: 0;
                box-sizing: border-box;
            }

            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                background-color: #f8f9fa;
                height: 100vh;
                overflow: hidden;
            }

            .navbar {
                position: fixed;
                top: 0;
                left: 0;
                right: 0;
                height: 60px;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                display: flex;
                align-items: center;
                justify-content: center;
                z-index: 1000;
                box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            }

            .nav-buttons {
                display: flex;
                gap: 20px;
            }

            .nav-button {
                padding: 12px 24px;
                background: rgba(255, 255, 255, 0.2);
                border: 2px solid rgba(255, 255, 255, 0.3);
                border-radius: 8px;
                color: white;
                text-decoration: none;
                font-weight: 600;
                font-size: 16px;
                cursor: pointer;
                transition: all 0.3s ease;
                backdrop-filter: blur(10px);
            }

            .nav-button:hover {
                background: rgba(255, 255, 255, 0.3);
                border-color: rgba(255, 255, 255, 0.5);
                transform: translateY(-2px);
            }

            .nav-button.active {
                background: rgba(255, 255, 255, 0.4);
                border-color: rgba(255, 255, 255, 0.6);
                box-shadow: 0 4px 15px rgba(0, 0, 0, 0.2);
            }

            .content {
                position: fixed;
                top: 60px;
                left: 0;
                right: 0;
                bottom: 0;
            }

            .iframe-container {
                width: 100%;
                height: 100%;
                display: none;
            }

            .iframe-container.active {
                display: block;
            }

            iframe {
                width: 100%;
                height: 100%;
                border: none;
            }

            .loading {
                position: absolute;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                color: #666;
                font-size: 18px;
            }

            .spinner {
                border: 3px solid #f3f3f3;
                border-top: 3px solid #667eea;
                border-radius: 50%;
                width: 30px;
                height: 30px;
                animation: spin 1s linear infinite;
                margin: 0 auto 10px;
            }

            @keyframes spin {
                0% { transform: rotate(0deg); }
                100% { transform: rotate(360deg); }
            }

            /* Mobile responsiveness */
            @media (max-width: 768px) {
                .navbar {
                    height: 50px;
                }
                
                .content {
                    top: 50px;
                }
                
                .nav-button {
                    padding: 8px 16px;
                    font-size: 14px;
                }
                
                .nav-buttons {
                    gap: 10px;
                }
            }

            @media (max-width: 480px) {
                .nav-button {
                    padding: 6px 12px;
                    font-size: 12px;
                }
            }
        </style>
    </head>
    <body>
        <div class="navbar">
            <div class="nav-buttons">
                <button class="nav-button active" onclick="switchApp('docs')">📚 Docs</button>
                <button class="nav-button" onclick="switchApp('matrix')">💬 Matrix</button>
            </div>
        </div>

        <div class="content">
            <div id="docs-container" class="iframe-container active">
                <div class="loading" id="docs-loading">
                    <div class="spinner"></div>
                    <div>Loading Docs...</div>
                </div>
                <iframe id="docs-iframe" src="https://${DOCS_HOST}" onload="hideLoading('docs-loading')"></iframe>
            </div>
            
            <div id="matrix-container" class="iframe-container">
                <div class="loading" id="matrix-loading">
                    <div class="spinner"></div>
                    <div>Loading Matrix...</div>
                </div>
                <iframe id="matrix-iframe" src="https://${MATRIX_HOST}" onload="hideLoading('matrix-loading')"></iframe>
            </div>
        </div>

        <script>
            let currentApp = 'docs';
            let loadedApps = new Set(['docs']); // Docs loads by default
            const DOCS_URL = 'https://${DOCS_HOST}';
            const MATRIX_URL = 'https://${MATRIX_HOST}';

            function switchApp(app) {
                if (app === currentApp) return;
                
                // Update button states
                document.querySelectorAll('.nav-button').forEach(btn => btn.classList.remove('active'));
                event.target.classList.add('active');
                
                // Hide current iframe
                document.getElementById(currentApp + '-container').classList.remove('active');
                
                // Show new iframe
                document.getElementById(app + '-container').classList.add('active');
                
                // Lazy load iframe if not already loaded
                if (!loadedApps.has(app)) {
                    const iframe = document.getElementById(app + '-iframe');
                    const loading = document.getElementById(app + '-loading');
                    loading.style.display = 'block';
                    
                    // Load the iframe
                    iframe.src = app === 'docs' ? DOCS_URL : MATRIX_URL;
                    loadedApps.add(app);
                }
                
                currentApp = app;
            }

            function hideLoading(loadingId) {
                const loading = document.getElementById(loadingId);
                if (loading) {
                    loading.style.display = 'none';
                }
            }

            // Handle iframe errors
            document.getElementById('docs-iframe').onerror = function() {
                hideLoading('docs-loading');
                console.error('Failed to load Docs iframe');
            };

            document.getElementById('matrix-iframe').onerror = function() {
                hideLoading('matrix-loading');
                console.error('Failed to load Matrix iframe');
            };

            // Keyboard shortcuts
            document.addEventListener('keydown', function(e) {
                if (e.ctrlKey) {
                    switch(e.key) {
                        case '1':
                            e.preventDefault();
                            switchApp('docs');
                            break;
                        case '2':
                            e.preventDefault();
                            switchApp('matrix');
                            break;
                    }
                }
            });
        </script>
    </body>
    </html>
