(function() {
  Danbooru.meta = function(key) {
    return $("meta[name=" + key + "]").attr("content");
  }
  
  Danbooru.j_alert = function(title, msg) {
    $('<div title="' + title + '"></div>').html(msg).dialog();
  }
  
  Danbooru.j_error = function(msg) {
    this.j_alert("Error", msg);
  }
  
  Danbooru.ajax_start = function(target) {
    $(target).after(' <img src="/images/wait.gif" width="15" height="5" class="wait">');
  }
  
  Danbooru.ajax_stop = function(target) {
    $(target).next("img.wait").remove();
  }
})();
