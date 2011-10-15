use strict;
use warnings;
use Test::More 0.96;

my $mod = 'Config::MVP::Slicer';
eval "require $mod" or die $@;

my $slicer = new_ok($mod, [{
  config => {
    opt                 => 'main config val',
    'Plug.attr'         => 'pa',
    'Mod::Name.opt'     => 'val',
    'Moose.and[]'       => 'squirrel',
    'Hunting.season[0]' => 'duck',
    'Hunting.season[1]' => 'wabbit',
    'Hunting.season[9]' => 'fudd',
  },
}]);

is_deeply
  $slicer->slice([Plug => 'X::Plug' => {}]),
  { attr => 'pa' },
  'matches on plugin name';

my $previous = { unused => 'config' };
is_deeply
  $slicer->slice([ModName => 'Mod::Name' => $previous ]),
  { opt => 'val' },
  'matches on class name';

is_deeply $previous, { unused => 'config' }, 'slice leaves conf untouched';

is_deeply
  $slicer->slice([Moose => Moose => {}]),
  { and => [qw(squirrel)] },
  'received array ref when specified as []';

is_deeply
  $slicer->slice([Hunting => 'X::Hunting' => {}]),
  { season => [qw(duck wabbit fudd)] },
  'received array ref containing all items';

done_testing;
