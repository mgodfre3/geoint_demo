FROM nginx:1.27-alpine

# Create non-root user and set up nginx to run as that user
RUN adduser -D -u 1001 appuser \
    && chown -R appuser:appuser /var/cache/nginx /var/log/nginx /etc/nginx/conf.d

# Copy static UI
COPY index.html /usr/share/nginx/html/index.html

# Minimal nginx config: serve static files, proxy /api/alerts to alert-processor
COPY nginx.conf /etc/nginx/conf.d/default.conf

USER appuser
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
