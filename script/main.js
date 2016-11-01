function filterAll () {
    // TODO: This might apply to other selectors
    var legal = Cookies.get('legal') || 'all';
    filterCardClass(
        legal == 'all' ? 'all' : 'legal-' + legal
    );
}

function filterCardClass (cls) {
    if ( ! $('DIV.cardsection').length ) return 0;

    $('DIV.cardsection, DIV.card').show();
    if (cls == 'all') return 1;

    // Hide the negative set
    $('DIV.card').not('.' + cls).hide();

    // Hide sections without cards
    $('DIV.cardsection').each(function() {
        var $this = $(this);
        if ( ! $this.find('DIV.card:visible').length ) $this.hide();
    });

    return 1;
}

function getFilterCookie ($select) {
    var val = Cookies.get( $select.attr('name') );
    if (val !== undefined) $select.val( val );
}

function setFilterCookie ($select) {
    Cookies.set( $select.attr('name'), $select.val() );
}

$(function() {
    var $selects = $('#form-filters select');

    $selects.each(function() {
        getFilterCookie( $(this) );
    });
    $selects.change(function () {
        setFilterCookie( $(this) );
        filterAll();
    });

    filterAll();
});
