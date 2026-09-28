# Signaler une vulnérabilité

Merci de **ne pas** ouvrir d'issue publique pour une faille de sécurité.

Écrivez à **cheickdioubate2@gmail.com** avec :
- la version concernée (visible dans la page « À propos » ou avec `dioubate-siem-server -version`) ;
- une description du problème et les étapes pour le reproduire ;
- l'impact estimé.

Vous recevrez un accusé de réception. Un correctif est publié dans une nouvelle version signée, et le signalement est crédité si vous le souhaitez.

## Vérifier l'authenticité d'une version

- Comparez l'empreinte SHA-256 de chaque fichier avec `SHA256SUMS.txt`.
- Le `manifest.json` des mises à jour est signé Ed25519. Les agents refusent tout manifeste dont la signature est invalide.
- Téléchargez uniquement depuis la page **Releases** de ce dépôt.
