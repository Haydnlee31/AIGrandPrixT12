import json
from fastapi.testclient import TestClient
from backend.tests.test_local_recommendations import database,find,request
from backend.app.capture_preview import create_app
from backend.app.local_recommendations import LocalRecommendationService,recommend,_profile,RecommendationFind
from backend.app.discovery import starter_cards,selection

def test_starters_are_diverse_sourced_and_rotate(database):
 factory,_=database;s=LocalRecommendationService(factory)
 first=starter_cards(s,[])
 assert len(first)>=3
 assert all(c['image_url'] and '/dp/' in c['product_url'] for c in first)
 second=starter_cards(s,[c['id'] for c in first])
 assert not set(c['id'] for c in first)&set(c['id'] for c in second)
 assert not any('box' in c['title'].lower() or 'pillow' in c['title'].lower() for c in first)

def test_selection_changes_results_with_explicit_color(database):
 factory,_=database;s=LocalRecommendationService(factory)
 card=next(c for c in starter_cards(s,[]) if 'watch' in c['title'].lower())
 for color in ['black','blue']:
  adapted=selection(s,card['id'],color+' watch')
  result=recommend(factory,adapted)
  assert result.items and all(color in i.title.lower() for i in result.items)
 assert selection(s,'does-not-exist','watch') is None

def test_discovery_auth_and_no_saves_required(database):
 factory,_=database
 app=create_app(api_key='test',token='test-token',recommendation_factory=factory)
 with TestClient(app) as client:
  assert client.post('/v1/discover',json={}).status_code==401
  response=client.post('/v1/discover',json={},headers={'Authorization':'Bearer test-token'})
  assert response.status_code==200 and response.json()['items']
  invalid=client.post('/v1/discover',json={'selected_id':'unknown'},headers={'Authorization':'Bearer test-token'})
  assert invalid.json()['status']=='selection_unavailable'

def test_brand_flexible_removes_brand_boost():
 f=RecommendationFind.model_validate(find())
 assert any(x.kind=='brand_match' for x in _profile(f).facets)
 f=f.model_copy(update={'intents':['Brand flexible']})
 assert not any(x.kind=='brand_match' for x in _profile(f).facets)


def test_personalization_cites_confirmed_detail_and_original_save(database):
 from backend.app.discovery import personalized_cards
 factory,_=database
 items=personalized_cards(LocalRecommendationService(factory),
     [RecommendationFind.model_validate(find(intents=['I like the black dial']))], [])
 cross=[i for i in items if any('different direction' in r['text'] for r in i['reasons'])]
 assert cross and all('lamp' in i['title'].lower() for i in cross)
 assert all(r['find_id']=='saved-watch' and r['matched_value']=='black dial' for i in cross for r in i['reasons'])
 assert all(i['image_url'] and '/dp/' in i['product_url'] for i in items)

def test_observed_color_alone_does_not_claim_user_liked_it(database):
 from backend.app.discovery import personalized_cards
 factory,_=database
 source=find()
 source['analysis']['summary']='A black dial and silver case'
 items=personalized_cards(LocalRecommendationService(factory), [RecommendationFind.model_validate(source)], [])
 assert not any('different direction' in r['text'] for i in items for r in i['reasons'])
