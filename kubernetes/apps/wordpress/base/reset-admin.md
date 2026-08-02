kubectl exec -n wordpress wordpress-797b499869-hdwz4 -- php -r "require('/var/www/html/wp-load.php'); wp_set_password('your_new_password_here', 1);"
