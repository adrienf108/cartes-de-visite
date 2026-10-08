# Cartes de visite → Contacts + liste d'appels

Un tas de cartes de visite, une webcam, et c'est tout. Faites défiler les cartes devant la caméra : chaque carte devient une fiche dans Contacts (Mac et iPhone) et une ligne dans une liste d'appels Excel.

*English: a macOS tool that turns a stack of business cards into Apple Contacts entries and an Excel call list. Show the cards to your webcam; on-device OCR (Apple Vision) captures each card hands-free, then Claude reads the photo and text to build clean contact records. The prompt and docs are in French and phone numbers default to France, but it works with any card.*

## Comment ça marche

1. **Capture à la caméra, sans les mains.** Une fenêtre montre l'image de la caméra. Quand le texte d'une carte se lit deux fois de suite à l'identique, elle est enregistrée : un son, un cadre vert, et on passe à la suivante. La lecture du texte (Apple Vision) se fait sur le Mac.
2. **Lecture par Claude.** Les cartes partent par lots à `claude -p` (Claude Code) : la photo recadrée et le texte lu par le Mac. Claude en tire des fiches propres (prénom, nom, société, poste, téléphones, e-mails, adresse, secteur). Il réunit le recto et le verso d'une même carte et écarte vos propres cartes.
3. **Contrôles.** Chaque numéro doit figurer sur la carte et est normalisé avec `phonenumbers`. Chaque e-mail est comparé au texte lu. Au moindre doute, la fiche est marquée « À vérifier ».
4. **Contacts.** Les nouvelles fiches vont dans un groupe dédié. Une personne déjà présente (même e-mail personnel, même mobile ou même nom et société) n'est pas recréée.
5. **Liste d'appels.** Le fichier `Liste d'appels.xlsx` a une colonne Statut avec un menu déroulant (À appeler, Messagerie, À rappeler, RDV pris…). Les numéros se composent d'un tap sur l'iPhone, et chaque ligne a un lien vers la photo de la carte. Le script ne fait qu'ajouter des lignes : vos statuts et vos notes ne sont jamais écrasés.

## Prérequis

- Un Mac sous macOS 14 ou plus récent, avec une webcam ou un iPhone en caméra de continuité.
- Les outils en ligne de commande de Xcode, pour `swiftc` : `xcode-select --install`.
- [uv](https://docs.astral.sh/uv/), pour lancer le script Python et ses dépendances.
- [Claude Code](https://claude.com/claude-code), connecté à votre abonnement Claude (voir ci-dessous).

## Utiliser son abonnement Claude

L'outil n'a pas de clé d'API à configurer. Il appelle `claude -p` (Claude Code en mode non interactif), qui utilise le compte avec lequel Claude Code est connecté. Avec un abonnement Claude Pro ou Max (ou une place Team ou Enterprise qui inclut Claude Code), la lecture des cartes passe donc par cet abonnement.

1. **Installer Claude Code** :

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   Autres méthodes (Homebrew, npm) : voir la [documentation de Claude Code](https://claude.com/claude-code).

2. **Se connecter avec son abonnement** :

   ```bash
   claude auth login
   ```

   Le navigateur s'ouvre sur claude.ai. Connectez-vous avec le compte qui porte l'abonnement. L'option `--claudeai` (abonnement) est celle par défaut ; `--console` facturerait à l'usage via la console Anthropic.

3. **Vérifier** :

   ```bash
   claude auth status --text
   ```

   Le statut doit indiquer une connexion par claude.ai et le type d'abonnement (pro, max…). Ensuite, `claude -p "Bonjour"` doit répondre.

**Bon à savoir**

- **Variable `ANTHROPIC_API_KEY`** : si elle est définie dans votre terminal, Claude Code peut s'en servir à la place de l'abonnement, et l'usage est alors facturé sur la clé. Pour rester sur l'abonnement, retirez-la : `unset ANTHROPIC_API_KEY`.
- **Limites d'usage** : chaque lot de cartes compte dans les limites de votre abonnement, comme un message. Les lots sont petits : environ 12 cartes, avec la photo recadrée et le texte de chacune. Si une limite est atteinte, le lot échoue proprement ; relancez `./cartes traiter` plus tard pour le reprendre.
- **Modèle** : Sonnet par défaut. `CARTES_MODELE="haiku"` dans le fichier de réglages consomme moins, mais lit un peu moins bien les cartes difficiles.

## Installation

```bash
git clone https://github.com/adrienf108/cartes-de-visite.git
cd cartes-de-visite
./cartes
```

Le premier lancement compile l'outil Swift. macOS demande ensuite l'accès à la **Caméra**, puis aux **Contacts**, pour l'app qui lance le script (Terminal, par exemple).

## Utilisation

```bash
./cartes --source "Salon VivaTech"           # scanner, puis traiter
./cartes --camera iPhone                     # une autre caméra (voir ./cartes cameras)
./cartes --camera "Desk View"                # l'iPhone posé sur l'écran filme le bureau
./cartes photos --source "Salon X" *.jpg     # des photos déjà prises, une carte par photo
./cartes traiter                             # relancer le traitement (reprend ce qui a échoué)
```

Pendant le scan :

- `Échap` termine.
- `Espace` force la capture.
- `⌫` annule la dernière carte.

**Recto et verso.** Montrez le recto, retournez la carte, montrez le verso, puis passez à la carte suivante. Les deux faces sont réunies en une seule fiche.

**Astuce.** Placez la caméra au-dessus de la pile. Vous retirez la carte du dessus, la suivante est lue. Plus la carte remplit l'image, plus la lecture est fiable.

## Réglages

Copiez `config.exemple` dans `~/.config/cartes-de-visite/config` :

| Variable | Rôle | Par défaut |
|---|---|---|
| `CARTES_DOSSIER` | Dossier des données (photos, fiches, liste) | `~/Documents/Cartes de visite` |
| `CARTES_GROUPE` | Groupe Contacts des nouvelles fiches | `Cartes de visite` |
| `CARTES_IGNORER` | Vos propres cartes, à ne pas importer | (vide) |
| `CARTES_MODELE` | Modèle Claude qui lit les cartes | `sonnet` |

Pour retrouver la liste sur l'iPhone, choisissez un dossier dans iCloud Drive. Un seul Mac traite un dossier donné (fichier `.mac-de-traitement`), parce qu'iCloud ne coordonne pas deux Mac qui écrivent en même temps. Pour changer de Mac, attendez la fin de la synchronisation, puis lancez `./cartes traiter --changer-de-mac`.

## Données et confidentialité

- La lecture du texte (OCR) et la détection de la carte se font sur le Mac.
- La photo recadrée et le texte de chaque carte sont envoyés à Claude (Anthropic) via Claude Code, en session isolée : sans outils, sans mémoire, sans historique de session.
- Tout le reste reste chez vous : `scans/` (photos et texte lu), `personnes.json` (fiches), `traitees.json` (suivi des cartes) et `Liste d'appels.xlsx`.
- Le dépôt ne contient aucune clé ni aucun identifiant.

## Fichiers

- `cartes` : le point d'entrée (zsh).
- `cartes.swift` : la caméra (AVFoundation), l'OCR (Vision), le recadrage et l'écriture dans Contacts.
- `traiter.py` : la lecture par Claude, les contrôles, les contacts et la liste d'appels (script `uv`).

## Licence

MIT
