FROM nginx:alpine

# Copy custom Nginx configuration
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy static website files
COPY . /usr/share/nginx/html

# Expose port 80 for Render
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
