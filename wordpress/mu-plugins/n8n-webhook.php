<?php
/**
 * Plugin Name: Webhook n8n
 * Description: Envoie un webhook à n8n quand un article est publié.
 * Chargement automatique (mu-plugins), pas besoin de l'activer dans wp-admin.
 */

add_action('transition_post_status', function ($new_status, $old_status, $post) {
    if ($post->post_type !== 'post') return;
    if ($new_status !== 'publish' || $old_status === 'publish') return;

    $url = getenv('N8N_WEBHOOK_URL') ?: 'http://n8n:5678/webhook/wordpress';

    wp_remote_post($url, [
        'timeout'  => 5,
        'blocking' => false, // ne bloque pas l'utilisateur qui publie
        'headers'  => ['Content-Type' => 'application/json'],
        'body'     => wp_json_encode([
            'event' => 'post_published',
            'title' => $post->post_title,
        ]),
    ]);
}, 10, 3);
