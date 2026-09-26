"""Relabels queries to match what the downloaded CC0 photos actually show (checked by eye on contact-sheet.jpg)."""
import json
import os

Q = {
    'dog-couch': 'the puppy on the couch',
    'hike-lake': 'the waterfall in the slot canyon',
    'sunset-city': 'everyone taking photos at the overlook at dusk',
    'sunset-ocean': 'the long pier under the cloudy sky',
    'cake-strawberry': 'the strawberry cake',
    'ramen': 'the street with all the little shops in Japan',
    'sushi': 'the salmon sushi platter',
    'pancakes': 'the diner table with all the sauces',
    'tacos': 'the grilled steak plate with lime',
    'new-car': 'the rusty old blue car',
    'bike': 'me cycling in my bike gear',
    'sneakers': 'the sneaker someone turned into a planter',
    'haircut': 'getting my haircut at the barber',
    'concert': 'the old theater marquee',
    'baseball': 'the old black and white baseball photo',
    'basketball': 'the old gym with the basketball hoops',
    'graduation': 'the Air Force Academy stadium crowd',
    'wedding': 'the Empire State Building lit up at night',
    'snow-cabin': 'the pencil sketch of the log cabin',
    'ski': 'the caution sign',
    'camping-tent': 'planning the route on the map',
    'flowers-tulips': 'the red and yellow tulip',
    'museum-dino': 'the lego dinosaur',
    'times-square': 'the vintage New York postcard',
    'farmers-market': 'the farmers market poster',
    'bookshelf': 'hanging out on the couch with the guys',
    'desk-setup': 'my laptop on the desk',
    'lego': 'the red lego ball',
    'painting': 'the hazy golden sky',
    'baby': 'the baby with the chocolate cupcake',
    'grandparents': 'the old family portrait',
    'friends-picnic': 'the yellow tree in the park',
    'thunderstorm': 'the storm clouds over the river',
    'fall-leaves': 'the willow trees by the pond',
    'pumpkins': 'the snowy mountain behind the farm fields',
    'christmas-tree': 'carrying in the christmas tree',
    'fireworks': 'the monorail by the water',
    'kitchen-reno': 'the textured ceiling',
    'apartment-keys': 'the empty bedroom in the new apartment',
    'moving-boxes': 'all the moving boxes in the kitchen',
    'fish-caught': 'the old photo of the fishing boat',
    'surf': 'the beach and coastline from above',
    'science-fair': 'the white car on the desert hill',
    'physics-notes': 'the ABC chalkboard drawing',
    'piano-recital': 'playing the grand piano',
    'horse': 'the husky puppy',
}

p = os.path.join(os.path.dirname(__file__), 'dataset.json')
d = json.load(open(p))
for i in d['images']:
    if i['id'] in Q:
        i['query'] = Q[i['id']]
d['note'] = ('Photos are CC0/public-domain from Openverse (see CREDITS.json). Queries describe what each photo actually shows, '
             'phrased the way the reference detector would output them; they were relabeled after checking contact-sheet.jpg. '
             '`negatives` have no matching image and are used to tune the similarity threshold.')
json.dump(d, open(p, 'w'), indent=2)
print('relabeled', len(Q))
