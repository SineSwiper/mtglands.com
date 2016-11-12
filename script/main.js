function filterAll () {
    // Start off with all cards and then filter everything down
    $('DIV.cardsection, DIV.card').show();

    // Legality filters
    var legal = Cookies.get('legal') || 'all';
    if (legal != 'all') filterCardClass('.legal-' + legal);

    // Color Identity filters (including subsets)
    var ci    = Cookies.get('ci') || 'all';
    if (ci == 'all' || ci == 'WUBRG') {
        // Do nothing
    }
    else if (ci == 'C') {
        filterCardClass('.ci-C');
    }
    else {
        // Figure out every color combination subset
        var colors      = ci.split('');
        var colorCombos = ['C'];  // 0 = C
        var bitmapMax   = 2 ** ci.length - 1;

        for (var comboNum = 1; comboNum <= bitmapMax; comboNum++) {
            var color = '';

            // Convert to binary with zero-padding
            var bitmap = ( '00000' + comboNum.toString(2) ).slice( -ci.length ).split('');

            for (var pos = 0; pos < colors.length; pos++) {
                if (bitmap[pos] == 1) color += colors[pos];
            }

            colorCombos.push(color);
        }

        // Filter by every combination of CI classes
        var cls = jQuery.map( colorCombos, function( a ) { return '.ci-' + a } ).join(',');
        filterCardClass(cls);
    }
}

function filterCardClass (cls) {
    if ( ! $('DIV.cardsection').length ) return 0;
    if (cls == 'all') return 1;

    // Hide the negative set
    $('DIV.card').not(cls).hide();

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
