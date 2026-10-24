"""The recommendation cannot swap product, image, or marketplace identities."""
from copy import deepcopy

import pytest

from backend.app.amazon_catalog_identity import amazon_asin, amazon_record_identity
from backend.app.catalog.service import import_dataset
from backend.app.local_recommendations import recommend
from backend.tests.test_local_recommendations import database, record, find, request


@pytest.mark.parametrize('url, expected', [
    ('https://www.amazon.com/dp/B07YQF7FBK?tag=reference', 'B07YQF7FBK'),
    ('https://amazon.co.uk/title/gp/product/B07YQF7FBK/ref=anything', 'B07YQF7FBK'),
    ('https://amazon.com.evil.test/dp/B07YQF7FBK', None),
    ('https://evil.test/?url=https://amazon.com/dp/B07YQF7FBK', None),
    ('https://amazon.com/s?k=B07YQF7FBK', None),
    ('https://amazon.com/dp/B07YQF7FBK1234', None),
    ('https://amazon.com@evil.test/dp/B07YQF7FBK', None),
    ('https://user@amazon.com/dp/B07YQF7FBK', None),
    ('https://amazon.com:123/dp/B07YQF7FBK', None),
    ('https://amazon.com/dp/350427319820040', None),
])
def test_only_explicit_valid_amazon_product_paths_are_ids(url, expected):
    assert amazon_asin(url) == expected


def test_exact_marketplace_and_own_photo_are_preserved():
    product = record('watch', 'Silver watch', 'WATCH')
    product['provenance']['domain_name'] = 'amazon.co.uk'
    asin, url, image = amazon_record_identity(product)
    assert url == f'https://www.amazon.co.uk/dp/{asin}'
    assert image == product['offer']['image_url']


@pytest.mark.parametrize('mutation', [
    lambda p: p.update(source_id='open_products_facts'),
    lambda p: p['provenance'].update(original_item_id='350427319820040'),
    lambda p: p['provenance'].update(original_item_id='abcdef'),
    lambda p: p['provenance'].update(source_record_id='MISMATCHED'),
    lambda p: p['provenance'].update(domain_name='amazon.com.evil.test'),
    lambda p: p['provenance'].update(domain_name='wholefoodsmarket.com'),
    lambda p: p['attributes'].pop('main_image_id'),
    lambda p: p['offer'].update(image_url=None),
    lambda p: p['offer'].update(image_url='https://other.example.org/watch.jpg'),
    lambda p: p['offer'].update(image_url='https://amazon-berkeley-objects.s3.us-east-1.amazonaws.com/images/small/ab/abcdef01.jpg?other=1'),
])
def test_incomplete_or_mixed_identity_is_not_publishable(mutation):
    product = record('watch', 'Silver watch', 'WATCH')
    mutation(product)
    assert amazon_record_identity(product) is None


def test_exact_saved_amazon_asin_precedes_similar_products(database):
    factory, _ = database
    target = record('silver-watch', 'Silver analog wristwatch', 'Watches', brand='Other')
    saved = find()
    saved['original_url'] = amazon_record_identity(target)[1]
    result = recommend(factory, request(saved))
    assert result.items[0].source_record_id == 'silver-watch'
    assert result.items[0].reasons[0].text == 'The same Amazon product you saved.'
    assert result.items[0].product_url == saved['original_url']
    assert result.items[0].price_minor is None


def test_smartwatch_never_returns_an_ordinary_wristwatch(database):
    factory, _ = database
    saved = find()
    saved['analysis']['product_name'] = 'Apple Watch Series 10 smartwatch'
    saved['analysis']['category_path'] = ['Electronics', 'Smartwatches']
    assert recommend(factory, request(saved)).status == 'no_matches'


def test_digital_watch_never_pads_results_with_analog_watch(database):
    factory, _ = database
    saved = find()
    saved['analysis']['product_name'] = 'Digital wristwatch'
    result = recommend(factory, request(saved))
    assert {item.source_record_id for item in result.items} == {'black-watch', 'blue-watch'}


def test_specific_preference_has_no_category_only_filler(database):
    factory, _ = database
    result = recommend(factory, request(find(intents=['silver retro watch'])))
    assert [item.source_record_id for item in result.items] == ['silver-watch']
    assert result.items[0].reasons[0].matched_value == 'silver'
    assert recommend(factory, request(find(intents=['purple ceramic watch']))).status == 'no_matches'


def test_mobile_phone_requires_positive_identity_not_just_generic_phone_category(database):
    factory, _ = database
    import_dataset(factory, 'abo', [
        record('foreign-landline', 'Geemarc Telescopio +60dB AMPLIPOWER50', 'PHONE'),
        record('headset', 'Amazon Basics Bluetooth Stereo Headset with Microphone', 'PHONE'),
        record('actual', 'Android smartphone', 'CELLULAR_PHONE'),
    ], version='specific-phone', checksum='6' * 64)
    saved = find('phone', 'phone')
    saved['analysis']['product_name'] = 'iPhone 17 Pro'
    result = recommend(factory, request(saved))
    assert [item.source_record_id for item in result.items] == ['actual']
