from .test_journey import client, save, drain, select_annotation


def test_copied_content_across_urls_has_one_support_group(client):
    first = save(client, 'original', selected_text='A warm desk with a compact lamp.')
    second = save(client, 'copy', selected_text='A WARM desk   with a compact lamp.')
    drain(client)
    select_annotation(client, first)
    select_annotation(client, second)
    hypothesis = client.get('/v1/hypotheses').json()['items'][0]
    assert hypothesis['independent_saves'] == 1
    assert hypothesis['status'] == 'collecting'
