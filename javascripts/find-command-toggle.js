$(function () {
    $('#toggle').click(function(){
        $('#find-command').toggle();

        if ($('#toggle').text() == "←") {
            $('#toggle').text("→");
        } else {
            $('#toggle').text("←");
        }
    });
});
