[🇫🇷 Français](README.fr.md) | [🇬🇧 English](README.md)

# IA Tetris entraînée par algorithme génétique

Un bot de Tetris écrit en OCaml, dont le comportement est contrôlé par 20 coefficients optimisés à l'aide d'un algorithme génétique.

Le meilleur individu élimine en moyenne environ **348 500 lignes par partie**, sur un plateau de 10 × 16 cases, avec des pièces tirées uniformément au hasard et sans aperçu de la pièce suivante.

Un bot jouant aléatoirement élimine moins d'une ligne par partie.

## 1. Contexte et règles

L'objectif est de tester jusqu'où un contrôleur simple et interprétable peut aller grâce à l'optimisation automatique, sans réseau de neurones ni réglage manuel. Le simulateur a été conçu pour évaluer très rapidement un grand nombre de placements au cours de parties longues.

| Règle | Paramètre |
|---|---|
| Plateau | 10 colonnes × 16 lignes |
| Pièces | 7 tétriminos classiques, tirés uniformément au hasard |
| Informations disponibles | Pièce actuelle uniquement, sans aperçu ni réserve |
| Placement | Chute verticale dans une colonne choisie, avec une rotation donnée |
| Score | Nombre de lignes éliminées |

## 2. Fonctionnement du bot

Pour chaque pièce, le bot évalue toutes les rotations et toutes les colonnes valides, simule le plateau obtenu, puis choisit le placement dont le coût est le plus faible.

Ce coût est une **combinaison linéaire de 20 caractéristiques du plateau**, inspirée des contrôleurs de Tetris de type Dellacherie. Ces caractéristiques décrivent notamment la hauteur d'atterrissage, le nombre de lignes éliminées, les irrégularités de la surface, les trous, les puits et les profils de hauteur souhaités.

L'algorithme génétique optimise un coefficient par caractéristique. Ces coefficients restent interprétables : leur signe et leur valeur absolue indiquent les propriétés du plateau que le bot favorise ou pénalise.

## 3. Algorithme génétique

Chaque individu contient 20 coefficients associés aux caractéristiques du plateau, ainsi que 20 pas de mutation correspondants (`sigma`). La fitness est mesurée par le nombre moyen de lignes éliminées au cours de 100 parties.

L'évaluation de la fitness étant coûteuse et stochastique, une méthode d'optimisation sans dérivées, fondée sur une population d'individus, est adaptée au problème. Chaque génération est sauvegardée sur le disque afin de pouvoir reprendre les longues sessions d'entraînement après une interruption.

## 4. Optimisations des performances

L'évaluation de 100 parties par individu, alors que les meilleurs bots survivent à plusieurs centaines de milliers de pièces, rend les performances du simulateur essentielles.

- **Plateau représenté par un masque binaire :** les 160 cases sont compactées dans 20 octets, ce qui permet de copier les plateaux à faible coût.
- **Précalculs :** les rotations des pièces et les plages de colonnes valides sont précalculées.
- **Élagage anticipé :** davantage de parties sont allouées aux candidats prometteurs.
- **Évaluation parallèle :** les individus sont répartis entre les cœurs du processeur grâce aux domaines d'OCaml 5 et à `Domainslib`.
- **Sauvegardes intermédiaires :** chaque génération est enregistrée pour permettre la reprise d'un entraînement interrompu.

## 5. Résultats

| Indicateur | Résultat |
|---|---:|
| Bot aléatoire | Moins d'une ligne par partie |
| Meilleur individu (génération 51) | Environ 348 500 lignes par partie |
| Évaluation de la fitness | Moyenne sur 100 parties par individu |
| Durée de l'entraînement | Environ 6 jours sur un ordinateur portable |

![Évolution du meilleur score](my_results/best_score_evolution.png)

Le meilleur individu et l'historique des évaluations sont disponibles dans [`my_results/best_individual.txt`](my_results/best_individual.txt) et [`my_results/fitness_history.csv`](my_results/fitness_history.csv).

Les estimations de fitness sont bruitées. Les candidats les plus performants ont été comparés sur un grand nombre de parties afin d'étayer le choix final. Pour obtenir un benchmark plus rigoureux, il faudrait évaluer les candidats sur les mêmes séquences de pièces, puis mesurer le score final sur des parties distinctes de celles utilisées pendant l'entraînement.

**Limite du benchmark :** le plateau de 10 × 16 cases et les règles simplifiées ne permettent pas de comparer directement ces résultats à ceux obtenus avec les règles classiques de Tetris.

## 6. Limites et pistes d'amélioration

| Domaine | Limite actuelle | Amélioration possible |
|---|---|---|
| Méthode d'optimisation | CMA-ES n'a pas été conservé ni évalué comparativement | Le comparer à l'algorithme génétique avec une méthode d'évaluation tenant compte du bruit |
| Recherche | Le contrôleur évalue les placements à l'aide d'une heuristique linéaire | Tester une recherche avec anticipation (*lookahead*) ou un algorithme *expectimax* tenant compte de l'incertitude sur les pièces futures |
| Bruit des évaluations | Les séquences aléatoires indépendantes rendent les comparaisons entre candidats plus bruitées | Évaluer les candidats sur des séquences de pièces communes |
| Sélection | En l'absence de sélection élitiste, le meilleur individu peut disparaître entre deux générations | Réévaluer les élites et comparer différentes stratégies d'élitisme |
| Coût de la fitness | Les dernières générations prennent entre 3 et 5 heures chacune | Accélérer le simulateur ou utiliser une évaluation progressive |
| Conception des caractéristiques | Certaines caractéristiques sont redondantes ou implémentées de manière non conventionnelle | Vérifier les caractéristiques et mesurer la contribution de chacune |
| Modèle du jeu | Les règles simplifiées limitent le réalisme et la comparabilité des résultats | Tester un plateau standard de 20 lignes, un générateur aléatoire par sacs de 7 pièces, l'aperçu des pièces, la réserve et les déplacements sous les surplombs |

### Particularités de l'implémentation

Certaines particularités des caractéristiques sont volontairement conservées, car les coefficients entraînés en dépendent. En particulier, la caractéristique *big holes* compte deux fois les trous, les colonnes vides peuvent être comptabilisées comme des trous, la hauteur moyenne des trous est mesurée depuis le sol et les caractéristiques exponentielles utilisent des exposants positifs. Corriger ces comportements nécessite de réentraîner le contrôleur.

## 7. Structure du projet

```text
.
├── bin/
│   └── main.ml
├── src/
│   ├── tetris.ml
│   └── genetic.ml
├── my_results/
│   ├── best_individual.txt
│   ├── fitness_history.csv
│   └── best_score_evolution.png
├── Makefile
├── README.fr.md
└── README.md
```

L'arborescence ci-dessus présente les principaux fichiers du projet ; d'autres fichiers de compilation et de données d'entraînement peuvent également être présents.

| Fichier ou répertoire | Rôle |
|---|---|
| `bin/main.ml` | Point d'entrée et paramètres d'entraînement |
| `src/tetris.ml` | Plateau, règles, caractéristiques, évaluation et simulation |
| `src/genetic.ml` | Opérateurs génétiques, évaluation parallèle, sauvegarde et chargement |
| `my_results/` | Mes résultats d'entraînement |

## 8. Compilation et exécution

**Prérequis :** OCaml 5 ou une version ultérieure. Aucune autre bibliothèque n'est nécessaire.

Le programme utilise le calcul parallèle.

```bash
make        # compile le programme ./main
make run    # compile et lance l'entraînement
make clean  # supprime les fichiers compilés
```

### Arrêter et reprendre l'entraînement

- **Arrêt :** l'entraînement ne s'arrête jamais de lui-même. Appuyez sur `Ctrl+C` lorsque la fitness cesse de s'améliorer.
- **Données sauvegardées :** chaque génération est enregistrée dans `runs/` (le répertoire défini par `save_dir` dans `bin/main.ml`) :
  - `population_gen_N.txt` : les 10 meilleurs individus de la génération `N` ;
  - `data.csv` : la moyenne des fitness des élites et la meilleure fitness de chaque génération, afin de suivre la progression.
- **Reprise :** dans `bin/main.ml`, définissez `load = Some n` pour reprendre à partir de la génération `n` et traiter la génération `n+1`. Conservez `load = None` pour repartir de zéro.
