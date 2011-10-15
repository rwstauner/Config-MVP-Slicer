use strict;
use warnings;
use Test::More 0.96;

my $mod = 'Config::MVP::Slicer';
eval "require $mod" or die $@;

my $slicer = new_ok($mod, [{
  config => {
    opt => 'val',
    'Plug.attr' => 'pa',
    'Mod::Name.-attr' => 'at',
  },
}]);

is_deeply
  $slicer->slice([Plug => 'X::Plug' => {}]),
  { attr => 'pa' },
  'matches on plugin name';

done_testing;
