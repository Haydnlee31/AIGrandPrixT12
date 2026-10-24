"""Cold-start exploration from real catalog rows, with session-only choices."""
import asyncio
import json
from pydantic import Field
from fastapi.responses import JSONResponse
from .local_recommendations import Contract, RecommendationFind, RecommendationRequest, FindAnalysis, _visible, _tokens
from .amazon_catalog_identity import amazon_record_identity
from .db import CatalogProduct
from .catalog.recommendation_index import category_product_ids
from .local_recommendations import _COLORS, _MATERIALS, _intent_terms, _preference_context, _profile, recommend

class DiscoveryRequest(Contract):
    selected_id: str | None = Field(default=None,max_length=128)
    dismissed: list[str] = Field(default_factory=list,max_length=40)
    brief: str = Field(default='',max_length=400)
    finds: list[RecommendationFind] = Field(default_factory=list,max_length=24)

FAMILIES=('watch','lamp','bag','chair','headphone','shoe','mug','clock')

def choice(identity,record):
    source=amazon_record_identity(record)
    if not source: return None
    _,url,image=source
    return {'id':identity,'title':record['title'],'image_url':image,'product_url':url,
        'source_id':'abo','source_record_id':record['source_record_id'],'source_name':'Amazon',
        'source_url':url,'license_url':'https://creativecommons.org/licenses/by/4.0/',
        'attribution':'Amazon Berkeley Objects dataset. Current price and availability need checking.',
        'discovery_hint': 'Explore ' + ' '.join([*sorted(set(_tokens(record['title'])) & (_COLORS | _MATERIALS))[:2], (record.get('category') or 'products').lower().replace('_',' ')]),
        'reasons':[],'score':0,'availability':'unknown','price_minor':None,'currency':None}

def starter_cards(service,dismissed):
    factory=service._factory()
    if factory is None:return []
    cards=[]
    with factory() as db:
        for family in FAMILIES:
            ids=category_product_ids(db,[family])
            query=_visible().where(CatalogProduct.id.in_(ids)) if ids is not None else _visible().where(CatalogProduct.record['category'].as_string().contains(family))
            rows=db.scalars(query.order_by(CatalogProduct.id).limit(100)).all()
            for row in rows:
                if row.id in dismissed:continue
                # Only the product's category can establish a family.
                category=(row.record.get('category') or '').lower()
                if family not in category or any(t in category for t in ['accessor','case','strap','replacement']):continue
                card=choice(row.id,row.record)
                if card:
                    cards.append(card);break
            if len(cards)==4:break
    return cards

def personalized_cards(service, finds, dismissed):
    factory=service._factory()
    if factory is None: return []
    source_finds=[f for f in finds if _profile(f)]
    if not source_finds: return []
    response=recommend(factory,RecommendationRequest(finds=source_finds,limit=24))
    cards=[i.model_dump() for i in response.items if i.id not in dismissed][:2]
    for item in cards:
        item['discovery_hint'] = 'Explore ' + item['title'][:180]
    seen={i['id'] for i in cards} | set(dismissed)
    for find in source_finds:
        terms,_=_intent_terms(find)
        parts=_preference_context(find,terms)
        physical=[t for t in terms if t in _COLORS or t in _MATERIALS]
        physical.sort(key=lambda t: (0 if 'dial' in parts.get(t,()) else 1 if parts.get(t) else 2))
        if not physical: continue
        term=physical[0]
        detail=term + (' '+parts[term][0] if parts.get(term) else '')
        origin=_profile(find).anchor[0].value
        for family in FAMILIES:
            if family==origin: continue
            probe=RecommendationFind(id=find.id,title=find.title,intents=[term],
                analysis=FindAnalysis(product_name=family,category_path=[family]))
            matches=recommend(factory,RecommendationRequest(finds=[probe],limit=6))
            # Relevance retrieval can match broad category tokens. Require the
            # actual catalog category to establish this new product family.
            with factory() as db:
                candidates = {row.id: row.record for row in db.scalars(
                    _visible().where(CatalogProduct.id.in_([i.id for i in matches.items]))).all()}
            candidate=next((i for i in matches.items if i.id not in seen
                and family in (candidates.get(i.id, {}).get('category') or '').lower()
                and not any(word in i.title.lower() for word in ['renewed', 'replacement'])
                and not any(word in (candidates.get(i.id, {}).get('category') or '').lower()
                            for word in ['accessor', 'case', 'strap', 'replacement'])),None)
            if candidate is None:continue
            item=candidate.model_dump()
            item['reasons']=[{'find_id':find.id,'find_title':find.title,
                'text':f'A different direction: {term}, inspired by the {detail} you liked.',
                'matched_value':detail}]
            item['discovery_hint']=f'Explore {term} {family}'
            cards.append(item);seen.add(item['id'])
            if len(cards)>=4:return cards
    return cards

def selection(service,identity,brief):
    factory=service._factory()
    if factory is None:return None
    with factory() as db:
        row=db.scalar(_visible().where(CatalogProduct.id==identity))
        if row is None or not amazon_record_identity(row.record):return None
        record=row.record
        return RecommendationRequest(finds=[RecommendationFind(id='discovery-session',title='Your discovery choice',
            intents=[brief] if brief else [],analysis=FindAnalysis(product_name=record['title'][:100],
                category_path=[(record.get('category') or '')[:100]],summary=''))],limit=12)

def register_discovery(app,service):
    @app.post('/v1/discover')
    async def discover(request:DiscoveryRequest):
        if request.selected_id:
            adapted=await asyncio.to_thread(selection,service,request.selected_id,request.brief)
            if adapted is None:return JSONResponse({'status':'selection_unavailable','items':[]},headers={'Cache-Control':'no-store'})
            response=await asyncio.to_thread(service.recommendations,adapted)
            value=json.loads(response.body)
            value['items']=[i for i in value.get('items',[]) if i['id'] not in request.dismissed and i['id']!=request.selected_id]
            for item in value['items']:
                item['discovery_hint']='Explore ' + ' '.join([*sorted(set(_tokens(item['title'])) & (_COLORS | _MATERIALS))[:2], adapted.finds[0].analysis.category_path[-1].lower().replace('_',' ')])
                for reason in item['reasons']:
                    reason['find_title']='Your discovery choice'
                    reason['text']=reason['text'].replace('your saved find','your choice').replace('your find','your choice')
            value['status']='ready' if value['items'] else 'no_matches'
            return JSONResponse(value,headers={'Cache-Control':'no-store'})
        if request.finds:
            items=await asyncio.to_thread(personalized_cards,service,request.finds,request.dismissed)
        else:
            items=await asyncio.to_thread(starter_cards,service,request.dismissed)
        return JSONResponse({'status':'ready' if items else 'no_matches','items':items},headers={'Cache-Control':'no-store'})
