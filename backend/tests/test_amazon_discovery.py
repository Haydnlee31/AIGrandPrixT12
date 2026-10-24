import json
import pytest
from backend.app.amazon_discovery import ProductPage,source_urls,compatible,AmazonDiscovery
from backend.app.local_recommendations import RecommendationFind,FindAnalysis

URL='https://www.amazon.sg/dp/B0CHXK8R1W'
HTML='''<input id="ASIN" value="B0CHXK8R1W"><span id="productTitle">Apple Watch Series 9 GPS</span><img id="landingImage" src="https://m.media-amazon.com/images/I/watch.jpg">'''
def test_model_invented_urls_are_not_search_sources():
 assert source_urls({'output':[{'type':'message','content':[{'text':URL}]}]})==[]
 assert source_urls({'output':[{'type':'web_search_call','action':{'sources':[{'url':URL},{'url':'https://evil.test/dp/B0CHXK8R1W'}]}}]})==[URL]
def test_primary_photo_and_identity_required():
 p=ProductPage();p.feed(HTML);assert p.result(URL)['title']=='Apple Watch Series 9 GPS'
 for text in [HTML.replace('B0CHXK8R1W','B000000000'),HTML.replace('landingImage','adImage'),HTML.replace('m.media-amazon.com','evil.test'),HTML+'<input id="captchacharacters">']:
  p=ProductPage();p.feed(text);assert p.result(URL) is None

def test_apple_watch_accessories_and_other_brands_rejected():
 f=RecommendationFind(id='watch',title='Apple Watch',analysis=FindAnalysis(product_name='Apple Watch',brand='Apple',category_path=['Smartwatches']))
 assert compatible(f,{'title':'Apple Watch Series 9 GPS'})
 assert not compatible(f,{'title':'Apple Watch strap'})
 assert not compatible(f,{'title':'Generic smartwatch'})

def test_iphone_case_is_not_phone():
 f=RecommendationFind(id='phone',title='iPhone',analysis=FindAnalysis(product_name='iPhone',brand='Apple',category_path=['Smartphones']))
 assert compatible(f,{'title':'Apple iPhone 14 Pro'})
 assert not compatible(f,{'title':'Case for Apple iPhone 14 Pro'})

def test_automatic_watch_does_not_become_digital():
 f=RecommendationFind(id='watch',title='Tudor self-winding watch',analysis=FindAnalysis(product_name='watch',category_path=['Watches']))
 assert not compatible(f,{'title':'Digital watch silver'})

def test_devices_mentioning_phone_are_not_smartphones():
 f=RecommendationFind(id='phone',title='Foldable smartphone',analysis=FindAnalysis(product_name='Foldable smartphone',category_path=['Smartphones']))
 for title in ['RENPHO Body Fat Scale with Smartphone App', 'Button Camera External Phone Camera for Android Smartphone']:
  assert not compatible(f,{'title':title})

def test_query_relevant_sources_precede_cables():
 sources=[{'url':'https://www.amazon.sg/Cable/dp/B000000001'},{'url':'https://www.amazon.sg/Apple-iPhone/dp/B000000002'}]
 assert source_urls({'output':[{'type':'web_search_call','action':{'sources':sources}}]},'Apple iPhone')[0].endswith('B000000002')
