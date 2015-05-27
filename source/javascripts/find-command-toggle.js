$(function () {
    $('#toggle').click(function(){
        $('#find-command').toggle();

        if ($('#toggle').text() == "Hide←") {
            $('#toggle').text("Expand→");
        } else {
            $('#toggle').text("Hide←");
        }
    });
});
