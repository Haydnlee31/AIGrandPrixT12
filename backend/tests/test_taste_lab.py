import pytest
from fastapi.testclient import TestClient
from backend.app.capture_preview import create_app, PreviewError
from backend.app.taste_lab import TastePlanner, TasteInterpreter, CatalogContext, Pair, Plan, Interpretation, InterpretationInput

def pair(**changes):
    return Pair(activity='Read comfortably',question='Which appeals to you?',dimension='Color',category='lamp',a_id='a',b_id='b',a_label='White',b_label='Black',source_find_id=None).model_copy(update=changes)

def context():
    return CatalogContext(goal='',finds=[],products=[{'id':'a','category':'lamp'},{'id':'b','category':'lamp'},{'id':'c','category':'chair'}])

@pytest.mark.parametrize('changes',[{'b_id':'missing'},{'b_id':'a'},{'b_id':'c'},{'source_find_id':'invented'},{'category':'watch'}])
def test_rejects_unverified_pairs(changes):
    service=TastePlanner(api_key='test',model='test')
    with pytest.raises(PreviewError): service._validate_response(Plan(cases=[pair(**changes)]),context())

def test_valid_pair_and_duplicate_rejection():
    service=TastePlanner(api_key='test',model='test')
    assert service._validate_response(Plan(cases=[pair()]),context()).cases
    with pytest.raises(PreviewError):service._validate_response(Plan(cases=[pair(),pair()]),context())

@pytest.mark.parametrize('choice',['Both','Neither'])
def test_ambiguous_choice_cannot_become_preference(choice):
    service=TasteInterpreter(api_key='test',model='test')
    request=InterpretationInput(pair=pair(),a_title='White lamp',b_title='Black lamp',choice=choice)
    result=service._validate_response(Interpretation(interpretation='Tentative',brief='Buy a lamp',category='lamp'),request)
    assert result.brief==''

def test_endpoints_require_auth():
    with TestClient(create_app(api_key='test',token='test-token')) as client:
        for route in ['/v1/taste-lab','/v1/taste-interpret']:
            assert client.post(route,json={}).status_code==401


def test_explicit_correction_preserved_even_when_model_brief_empty():
    service=TasteInterpreter(api_key='test',model='test')
    request=InterpretationInput(pair=pair(),a_title='White lamp',b_title='Black lamp',choice='A',clarification='Actually a silver watch')
    result=service._validate_response(Interpretation(interpretation='A new direction',brief='',category='watch'),request)
    assert result.brief=='Actually a silver watch'


def test_explicit_new_category_overrides_model_anchor():
    service=TasteInterpreter(api_key='test',model='test')
    request=InterpretationInput(pair=pair(),a_title='Watch A',b_title='Watch B',choice='A',clarification='Actually a warm reading lamp, not a watch')
    result=service._validate_response(Interpretation(interpretation='New direction',brief='',category='watch'),request)
    assert result.category=='lamp'
