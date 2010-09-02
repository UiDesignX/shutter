###################################################
#
#  Copyright (C) 2008, 2009, 2010 Mario Kemper <mario.kemper@googlemail.com> and Shutter Team
#
#  This file is part of Shutter.
#
#  Shutter is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#
#  Shutter is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with Shutter; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
###################################################

package Shutter::App::MainApp;

#modules
#--------------------------------------
use utf8;
use strict;
use Gtk2;

#Glib
use Glib qw/TRUE FALSE/; 

#filename parsing
use POSIX qw/ strftime /;

#File operations
use File::Copy qw/ cp mv /;
use File::Path qw/ rmtree /;
use File::Glob qw/ glob /;
use File::Basename qw/ fileparse dirname basename /;
use File::Temp qw/ tempfile tempdir /;
use IO::File();

#A selection of general-utility list subroutines
use List::Util qw/ max min /;

#load and save settings
use XML::Simple;

#DBus message system
use Net::DBus qw/ dbus_string dbus_boolean /;

#HTTP Status code processing
use HTTP::Status;

#timing issues
use Time::HiRes qw/ time usleep /;

#stringified perl data structures, suitable for both printing and eval
use Data::Dumper;

#md5 hash library
use Digest::MD5  qw(md5_hex);

#################################################
#################################################
use constant MAX_ERROR			=> 5;
use constant SHUTTER_REV		=> 'Rev.<>';
use constant SHUTTER_NAME		=> 'Shutter';
use constant SHUTTER_VERSION	=> '<major>.<minor>';
#################################################
#################################################

#--------------------------------------

sub new {
	my $class = shift;

	#constructor
	my $self = { };

	bless $self, $class;
	return $self;
}

sub run {
	my $self = shift;
	my $app = shift;
	my $shutter_root = shift;
	my $shutter_path = shift;
	my $gnome_web_photo = shift;
	my $nautilus_sendto = shift;
	my $goocanvas = shift;
	my $ubuntuone = shift;
	
	#main window
	#--------------------------------------
	my $window 	= Gtk2::Window->new('toplevel');
	#--------------------------------------

	#create app objects
	#--------------------------------------
	my $sc 		= Shutter::App::Common->new($shutter_root, $window, SHUTTER_NAME, SHUTTER_VERSION, SHUTTER_REV, $$);
	my $shf		= Shutter::App::HelperFunctions->new($sc);
	my $sm  	= Shutter::App::Menu->new($sc);
	my $st  	= Shutter::App::Toolbar->new($sc);
	my $sd 		= Shutter::App::SimpleDialogs->new($window);

	my $sp 		= Shutter::Pixbuf::Save->new($sc);
	my $sthumb 	= Shutter::Pixbuf::Thumbnail->new($sc);

	#--------------------------------------

	#Clipboard
	my $clipboard = Gtk2::Clipboard->get( Gtk2::Gdk->SELECTION_CLIPBOARD );

	#Gettext
	my $d = $sc->get_gettext;

	#Page Setup
	my $pagesetup = undef;

	#Tooltips
	my $tooltips = $sc->get_tooltips;

	#Gtk2::ImageView and Selector for advanced selection tool
	my $view 		= Gtk2::ImageView->new;
	my $selector 	= Gtk2::ImageView::Tool::Selector->new($view);
	my $dragger 	= Gtk2::ImageView::Tool::Dragger->new($view);
	$view->set_interpolation ('tiles');
	$view->set_tool($selector);

	#Gtk2::ImageView and Selector for drawing tool
	my $view_d;
	my $selector_d;
	my $dragger_d;
	if($goocanvas){
		$view_d     = Gtk2::ImageView->new;
		$selector_d = Gtk2::ImageView::Tool::Selector->new($view_d);
		$dragger_d 	= Gtk2::ImageView::Tool::Dragger->new($view_d);
		$view_d->set_interpolation ('tiles');	
		$view_d->set_tool($selector_d);
	}

	#UbuntuOne Client
	my $u1 = undef;
	my $u1_watcher = undef;

	#data structures
	#--------------------------------------
	my %plugins;        #hash to store plugin infos
	my %accounts;       #hash to store account infos
	my %settings;       #hash to store settings

	#init
	#--------------------------------------
	my @init_files; #array to store filenames (cmd arguments)

	# Watch the main window and register a handler that will be called each time
	# that there's a new message.
	$app->watch_window($window);
	$app->signal_connect('message-received' => sub {
		my ($app, $command, $message, $time) = @_;
		print Dumper @_;
		return 'ok';
	});

	&fct_init;
	&fct_init_debug_output if $sc->get_debug;
	&fct_load_accounts;

	#signal-handler
	$SIG{RTMIN}  = sub { &evt_take_screenshot( 'global_keybinding', 'select' ) };
	$SIG{USR1}   = sub { &evt_take_screenshot( 'global_keybinding', 'raw' ) };
	$SIG{USR2}   = sub { &evt_take_screenshot( 'global_keybinding', 'window' ) };
	$SIG{RTMAX}  = sub { &evt_take_screenshot( 'global_keybinding', 'section' ) };

	#shutdown Shutter carefully when INT or TERM are detected
	# => save settings
	$SIG{INT}    = sub { &evt_delete_window( '', 'quit' ) };
	$SIG{TERM}   = sub { &evt_delete_window( '', 'quit' ) };

	#hash of screenshots during session
	my %session_screens;
	my %session_start_screen;

	#main window gui
	#--------------------------------------
	$window->set_default_icon_name( "shutter" );
	$window->signal_connect( 'delete-event' => \&evt_delete_window );
	$window->set_border_width(0);
	$window->set_resizable(TRUE);
	$window->set_focus_on_map(TRUE);
	$window->set_default_size( -1, 500 );

	#TRAY ICON AND MENU
	my $tray                 = undef;
	my $tray_box			 = undef; #Gtk2::TrayIcon needs and Gtk2::EventBox 
	my $tray_menu			 = &fct_ret_tray_menu;

	#HELPERS
	my $current_profile_indx = 0; #current profile index
	my $is_hidden            = TRUE; #main window hidden flag

	#SESSION NOTEBOOK
	my $notebook = Gtk2::Notebook->new;
	$notebook = &fct_create_session_notebook;

	#STATUSBAR
	my $status = Gtk2::Statusbar->new;
	$status->set_name('main-window-statusbar');

	#customize the statusbar style
	Gtk2::Rc->parse_string (
		"style 'statusbar-style' {
			GtkStatusbar::shadow-type = GTK_SHADOW_NONE
		}
		widget '*.main-window-statusbar' style 'statusbar-style'"
	);
		
	my $combobox_status_profiles_label = Gtk2::Label->new( $d->get("Profile") . ":" );
	my $combobox_status_profiles = Gtk2::ComboBox->new_text;

	#arrange settings in notebook
	my $notebook_settings = Gtk2::Notebook->new;
	my $settings_dialog   = Gtk2::Dialog->new(
		SHUTTER_NAME . " - " . $d->get("Preferences"),
		$window,
		[qw/modal destroy-with-parent/],
		'gtk-close' => 'close'
	);
	$settings_dialog->set_has_separator(FALSE);

	my $vbox = Gtk2::VBox->new( FALSE, 0 );
	$window->add($vbox);

	#attach signal handlers to subroutines and pack menu
	#--------------------------------------
	$vbox->pack_start( $sm->create_menu, FALSE, TRUE, 0 );

	$sm->{_menuitem_open}->signal_connect( 'activate', \&evt_open, 'menu_open' );

	#recent manager and menu entry
	my $rmanager = Gtk2::RecentManager->new;
	$sm->{_menu_recent} = Gtk2::RecentChooserMenu->new_for_manager($rmanager); 
	$sm->{_menu_recent}->set_sort_type('mru');
	$sm->{_menu_recent}->set_local_only (TRUE);

	my $recentfilter = Gtk2::RecentFilter->new;
	$recentfilter->add_pixbuf_formats;
	$sm->{_menu_recent}->add_filter ($recentfilter);
	$sm->{_menu_recent}->signal_connect('item-activated' => \&evt_open);	
	$sm->{_menuitem_recent}->set_submenu($sm->{_menu_recent});	

	$sm->{_menuitem_redoshot}->signal_connect( 'activate', \&evt_take_screenshot, 'redoshot' );
	$sm->{_menuitem_selection}->signal_connect( 'activate', \&evt_take_screenshot, 'select' );
	$sm->{_menuitem_full}->signal_connect( 'activate', \&evt_take_screenshot, 'raw' );
	$sm->{_menuitem_window}->signal_connect( 'activate', \&evt_take_screenshot, 'window' );
	$sm->{_menuitem_section}->signal_connect( 'activate', \&evt_take_screenshot, 'section' );
	$sm->{_menuitem_menu}->signal_connect( 'activate', \&evt_take_screenshot, 'menu' );
	$sm->{_menuitem_tooltip}->signal_connect( 'activate', \&evt_take_screenshot, 'tooltip' );
	$sm->{_menuitem_iclipboard}->signal_connect( 'activate', \&fct_clipboard_import );

	#gnome web photo is optional, don't enable it when gnome-web-photo is not in PATH
	if($gnome_web_photo){
		$sm->{_menuitem_web}->set_sensitive(TRUE);
		$sm->{_menuitem_web}->signal_connect( 'activate', \&evt_take_screenshot, 'web' );
	}else{
		$sm->{_menuitem_web}->set_sensitive(FALSE);	
	}

	$sm->{_menuitem_save_as}->signal_connect( 'activate', \&evt_save_as, 'menu_save_as' );
	#~ $sm->{_menuitem_export_svg}->signal_connect( 'activate', \&evt_save_as, 'menu_export_svg' );
	$sm->{_menuitem_export_pdf}->signal_connect( 'activate', \&evt_save_as, 'menu_export_pdf' );
	$sm->{_menuitem_print}->signal_connect( 'activate', \&fct_print, 'menu_print' );
	$sm->{_menuitem_pagesetup}->signal_connect( 'activate', \&evt_page_setup, 'menu_pagesetup' );
	$sm->{_menuitem_email}->signal_connect( 'activate', \&fct_email, 'menu_email' );
	$sm->{_menuitem_close}->signal_connect( 'activate', sub { &fct_remove(undef, 'menu_close'); } );
	$sm->{_menuitem_close_all}->signal_connect( 'activate', sub { &fct_select_all; &fct_remove(undef, 'menu_close_all'); } );
	$sm->{_menuitem_quit}->signal_connect( 'activate', \&evt_delete_window, 'quit' );

	$sm->{_menuitem_undo}->signal_connect( 'activate', \&fct_undo );
	$sm->{_menuitem_redo}->signal_connect( 'activate', \&fct_redo );
	$sm->{_menuitem_copy}->signal_connect( 'activate', \&fct_clipboard, 'image' );
	$sm->{_menuitem_copy_filename}->signal_connect( 'activate', \&fct_clipboard, 'text' );
	$sm->{_menuitem_trash}->signal_connect( 'activate', sub { &fct_delete(undef); } );
	$sm->{_menuitem_select_all}->signal_connect( 'activate', \&fct_select_all );
	$sm->{_menuitem_settings}->signal_connect( 'activate', \&evt_show_settings );

	$sm->{_menuitem_btoolbar}->signal_connect( 'toggled', \&fct_navigation_toolbar );
	$sm->{_menuitem_zoom_in}->signal_connect( 'activate', \&fct_zoom_in );
	$sm->{_menuitem_zoom_out}->signal_connect( 'activate', \&fct_zoom_out );
	$sm->{_menuitem_zoom_100}->signal_connect( 'activate', \&fct_zoom_100 );
	$sm->{_menuitem_zoom_best}->signal_connect( 'activate', \&fct_zoom_best );
	$sm->{_menuitem_fullscreen}->signal_connect( 'toggled', \&fct_fullscreen );

	#screenshot menu
	$sm->{_menu_actions}->signal_connect( 'focus', sub { $sm->{_menuitem_reopen}->set_submenu(&fct_ret_program_menu); });
	$sm->{_menuitem_rename}->signal_connect( 'activate', \&fct_rename );
	$sm->{_menuitem_upload}->signal_connect( 'activate', \&fct_upload );

	#nautilus-sendto is optional, don't enable it when not installed
	if ( $nautilus_sendto ) {
		$sm->{_menuitem_send}->signal_connect( 'activate', \&fct_send );	
	}else{
		$sm->{_menuitem_send}->set_sensitive(FALSE);
	}	

	#goocanvas is optional, don't enable it when not installed
	if ( $goocanvas ) {
		$sm->{_menuitem_draw}->signal_connect( 'activate', \&fct_draw );
	}else{
		$sm->{_menuitem_draw}->set_sensitive(FALSE);	
	}

	$sm->{_menuitem_plugin}->signal_connect( 'activate', \&fct_plugin );
	$sm->{_menuitem_redoshot_this}->signal_connect( 'activate', \&evt_take_screenshot, 'redoshot_this' );

	#large screenshot menu
	$sm->{_menu_large_actions}->signal_connect( 'focus', sub { $sm->{_menuitem_large_reopen}->set_submenu(&fct_ret_program_menu); });
	$sm->{_menuitem_large_rename}->signal_connect( 'activate', \&fct_rename );
	$sm->{_menuitem_large_copy}->signal_connect( 'activate', \&fct_clipboard, 'image' );
	$sm->{_menuitem_large_copy_filename}->signal_connect( 'activate', \&fct_clipboard, 'text' );
	$sm->{_menuitem_large_trash}->signal_connect( 'activate', sub { &fct_delete(undef); } );
	$sm->{_menuitem_large_upload}->signal_connect( 'activate', \&fct_upload );

	#nautilus-sendto is optional, don't enable it when not installed
	if ( $nautilus_sendto ) {
		$sm->{_menuitem_large_send}->signal_connect( 'activate', \&fct_send );	
	}else{
		$sm->{_menuitem_large_send}->set_sensitive(FALSE);
	}	

	#goocanvas is optional, don't enable it when not installed
	if ( $goocanvas ) {
		$sm->{_menuitem_large_draw}->signal_connect( 'activate', \&fct_draw );
	}else{
		$sm->{_menuitem_large_draw}->set_sensitive(FALSE);	
	}

	$sm->{_menuitem_large_plugin}->signal_connect( 'activate', \&fct_plugin );
	$sm->{_menuitem_large_redoshot_this}->signal_connect( 'activate', \&evt_take_screenshot, 'redoshot_this' );

	#go to menu
	$sm->{_menuitem_back}->signal_connect( 'activate' => sub {
			$notebook->prev_page;
		}
	);
	$sm->{_menuitem_forward}->signal_connect( 'activate' => sub{
			$notebook->next_page;
		}
	);
	$sm->{_menuitem_first}->signal_connect( 'activate' => sub {
			$notebook->set_current_page(0);
		}
	);
	$sm->{_menuitem_last}->signal_connect( 'activate' => sub {
			$notebook->set_current_page( $notebook->get_n_pages - 1 );
		}
	);

	#help	
	$sm->{_menuitem_question}->signal_connect( 'activate', \&evt_question );
	$sm->{_menuitem_translate}->signal_connect( 'activate', \&evt_translate );
	$sm->{_menuitem_bug}->signal_connect( 'activate', \&evt_bug );
	$sm->{_menuitem_about}->signal_connect( 'activate', \&evt_about );

	#--------------------------------------

	#trayicon
	#--------------------------------------
	#command line param set to disable tray icon?
	unless ( $sc->get_disable_systray ) {
			
		if ( Gtk2->CHECK_VERSION( 2, 10, 0 ) ) {
			$tray = Gtk2::StatusIcon->new();
			
			$tray->set_from_icon_name("shutter-panel");
			$tray->set_visible(1);
			$tray->{'hid'} = $tray->signal_connect(
				'popup-menu' => sub { &evt_show_systray_statusicon; },
				$tray
			);
			$tray->{'hid2'} = $tray->signal_connect(
				'activate' => sub {
					&evt_activate_systray_statusicon;
					$tray;
				},
				$tray
			);
		} else {
			
			my $tray_image = Gtk2::Image->new_from_icon_name( 'shutter-panel', 'large-toolbar' );
			
			#eventbox with shutter logo
			$tray_box = Gtk2::EventBox->new;
			$tray_box->add($tray_image);

			#tray icon
			require Gtk2::TrayIcon;		
			$tray = Gtk2::TrayIcon->new('Shutter TrayIcon');
			$tray->add($tray_box);
			$tray_box->{'hid'} = $tray_box->signal_connect( 'button_release_event', \&evt_show_systray );
			$tray->show_all;
		}

	}

	#--------------------------------------

	#settings
	#--------------------------------------
	my $vbox_settings       = Gtk2::VBox->new( FALSE, 12 );
	my $hbox_settings       = Gtk2::HBox->new( FALSE, 12 );
	my $vbox_basic          = Gtk2::VBox->new( FALSE, 12 );
	my $vbox_advanced       = Gtk2::VBox->new( FALSE, 12 );
	my $vbox_actions        = Gtk2::VBox->new( FALSE, 12 );
	my $vbox_imageview      = Gtk2::VBox->new( FALSE, 12 );
	my $vbox_behavior       = Gtk2::VBox->new( FALSE, 12 );
	my $vbox_keyboard       = Gtk2::VBox->new( FALSE, 12 );
	my $vbox_accounts       = Gtk2::VBox->new( FALSE, 12 );

	#profiles
	my $profiles_box        = Gtk2::HBox->new( FALSE, 0 );

	#main
	my $file_vbox           = Gtk2::VBox->new( FALSE, 0 );
	my $save_vbox           = Gtk2::VBox->new( FALSE, 0 );
	my $capture_vbox        = Gtk2::VBox->new( FALSE, 0 );

	my $scale_box           = Gtk2::HBox->new( FALSE, 0 );
	my $filetype_box        = Gtk2::HBox->new( FALSE, 0 );
	my $filename_box        = Gtk2::HBox->new( FALSE, 0 );
	my $saveDir_box         = Gtk2::HBox->new( FALSE, 0 );
	my $save_ask_box        = Gtk2::HBox->new( FALSE, 0 );
	my $save_auto_box       = Gtk2::HBox->new( FALSE, 0 );
	my $no_autocopy_box  	= Gtk2::HBox->new( FALSE, 0 );
	my $image_autocopy_box  = Gtk2::HBox->new( FALSE, 0 );
	my $fname_autocopy_box  = Gtk2::HBox->new( FALSE, 0 );
	my $delay_box           = Gtk2::HBox->new( FALSE, 0 );
	my $cursor_box          = Gtk2::HBox->new( FALSE, 0 );

	#keybindings
	my $sel_capture_vbox    = Gtk2::VBox->new( FALSE, 0 );
	my $asel_capture_vbox   = Gtk2::VBox->new( FALSE, 0 );

	my $keybinding_mode_box = Gtk2::HBox->new( TRUE,  0 );
	my $key_box             = Gtk2::HBox->new( FALSE, 0 );
	my $key_sel_box         = Gtk2::HBox->new( FALSE, 0 );

	#actions
	my $actions_vbox        = Gtk2::VBox->new( FALSE, 0 );

	my $progname_box        = Gtk2::HBox->new( FALSE, 0 );
	my $im_colors_box       = Gtk2::HBox->new( FALSE, 0 );
	my $thumbnail_box       = Gtk2::HBox->new( FALSE, 0 );
	my $bordereffect_box	= Gtk2::HBox->new( FALSE, 0 );

	#advanced
	my $window_capture_vbox = Gtk2::VBox->new( FALSE, 0 );
	my $menu_capture_vbox   = Gtk2::VBox->new( FALSE, 0 );
	my $web_capture_vbox    = Gtk2::VBox->new( FALSE, 0 );

	my $zoom_box			= Gtk2::HBox->new( FALSE, 0 );
	my $as_help_box			= Gtk2::HBox->new( FALSE, 0 );
	my $asel_isize_box      = Gtk2::HBox->new( FALSE, 0 );
	my $asel_isize_box2     = Gtk2::HBox->new( FALSE, 0 );
	my $border_box          = Gtk2::HBox->new( FALSE, 0 );
	my $visible_windows_box = Gtk2::HBox->new( FALSE, 0 );
	my $menu_delay_box      = Gtk2::HBox->new( FALSE, 0 );
	my $menu_waround_box    = Gtk2::HBox->new( FALSE, 0 );
	my $web_width_box       = Gtk2::HBox->new( FALSE, 0 );

	#imageview
	my $transparent_vbox    = Gtk2::VBox->new( FALSE, 0 );
	my $imageview_hbox1     = Gtk2::HBox->new( FALSE, 0 );
	my $imageview_hbox2     = Gtk2::HBox->new( FALSE, 0 );
	my $imageview_hbox3     = Gtk2::HBox->new( FALSE, 0 );

	#behavior
	my $window_vbox       	= Gtk2::VBox->new( FALSE, 0 );
	my $notify_vbox       	= Gtk2::VBox->new( FALSE, 0 );
	my $trash_vbox       	= Gtk2::VBox->new( FALSE, 0 );
	my $keybinding_vbox     = Gtk2::VBox->new( FALSE, 0 );

	my $hide_active_hbox    = Gtk2::HBox->new( FALSE, 0 );
	my $pafter_active_hbox  = Gtk2::HBox->new( FALSE, 0 );
	my $cac_hbox			= Gtk2::HBox->new( FALSE, 0 );
	my $hide_time_hbox      = Gtk2::HBox->new( FALSE, 0 );
	my $na_active_hbox      = Gtk2::HBox->new( FALSE, 0 );
	my $nt_active_hbox      = Gtk2::HBox->new( FALSE, 0 );
	my $npt_active_hbox     = Gtk2::HBox->new( FALSE, 0 );
	my $ns_combo_hbox       = Gtk2::HBox->new( FALSE, 0 );
	my $aod_active_hbox     = Gtk2::HBox->new( FALSE, 0 );
	my $doc_active_hbox     = Gtk2::HBox->new( FALSE, 0 );

	#upload
	my $accounts_vbox       = Gtk2::VBox->new( FALSE, 0 );
	my $ftp_vbox            = Gtk2::VBox->new( FALSE, 0 );

	my $accounts_hbox       = Gtk2::HBox->new( FALSE, 0 );
	my $ftp_hbox1           = Gtk2::HBox->new( FALSE, 0 );
	my $ftp_hbox2           = Gtk2::HBox->new( FALSE, 0 );
	my $ftp_hbox3           = Gtk2::HBox->new( FALSE, 0 );
	my $ftp_hbox4           = Gtk2::HBox->new( FALSE, 0 );
	my $ftp_hbox5           = Gtk2::HBox->new( FALSE, 0 );

	#plugins
	my $effects_vbox        = Gtk2::VBox->new( FALSE, 0 );

	#load settings
	#--------------------------------------
	my $settings_xml = &fct_load_settings( "start" );

	#load last profile
	if ( defined $settings_xml->{'general'}->{'last_profile'} ) {
		if ( $settings_xml->{'general'}->{'last_profile'} != -1 ) {
			$settings_xml = &fct_load_settings("start", $settings_xml->{'general'}->{'last_profile_name'} );
		}
	}

	#--------------------------------------

	#block signals while checking plugins / opening files
	&fct_control_signals('block');

	#check plugins
	#--------------------------------------
	#not used in a standalone environment
	unless($ENV{PAR_TEMP}){
		&fct_check_installed_plugins;
	}

	$vbox->pack_start( $st->create_toolbar, FALSE, TRUE, 0 );

	$st->{_redoshot}->signal_connect( 'clicked' => \&evt_take_screenshot, 'redoshot' );
	$st->{_redoshot}->set_sensitive(FALSE);

	my ( $tool_advanced, $tool_simple ) = undef;
	$st->{_select}->set_menu(&fct_ret_sel_menu);
	$st->{_select}->signal_connect( 'clicked' => \&evt_take_screenshot, 'select' );

	my $current_monitor_active = undef;
	$st->{_full}->signal_connect( 'clicked' => \&evt_take_screenshot, 'raw' );

	#init menus
	$st->{_full}->set_menu( &fct_ret_workspace_menu(TRUE) );	
	$st->{_window}->set_menu( &fct_ret_window_menu );	

	#and attach signal handlers
	$st->{_full}->signal_connect( 'show-menu' => sub { $st->{_full}->set_menu( &fct_ret_workspace_menu(FALSE) ) } );
	$st->{_window}->signal_connect( 'clicked' => \&evt_take_screenshot, 'window' );

	$st->{_window}->signal_connect( 'show-menu' => sub { $st->{_window}->set_menu( &fct_ret_window_menu ) } );
	$st->{_section}->signal_connect( 'clicked' => \&evt_take_screenshot, 'section' );
	$st->{_menu}->signal_connect( 'clicked' => \&evt_take_screenshot, 'menu' );
	$st->{_tooltip}->signal_connect( 'clicked' => \&evt_take_screenshot, 'tooltip' );

	#gnome-web-photo is optional, don't enable it when gnome-web-photo is not in PATH
	if ( $gnome_web_photo ) {
		$st->{_web}->set_sensitive(TRUE);
		$st->{_web}->signal_connect( 'clicked' => \&evt_take_screenshot, 'web' );
		$st->{_web}->set_menu(&fct_ret_web_menu);
		$st->{_web}->signal_connect( 'show-menu' => \&fct_ret_web_menu );
	} else {
		$tooltips->set_tip( $st->{_web}, $d->get("gnome-web-photo needs to be installed for this feature") );
		$st->{_web}->set_arrow_tooltip( $tooltips, $d->get("gnome-web-photo needs to be installed for this feature"), '' );
		$st->{_web}->set_sensitive(FALSE);
	}

	#goocanvas is optional, don't enable it when not installed
	if ( $goocanvas ) {
		$st->{_edit}->signal_connect( 'clicked' => \&fct_draw );
	}else{
		$tooltips->set_tip( $st->{_edit}, $d->get("Goo::Canvas/libgoocanvas needs to be installed for this feature") );
	}
	$st->{_edit}->set_sensitive(FALSE);
		
	$st->{_upload}->signal_connect( 'clicked' => \&fct_upload );
	$st->{_upload}->set_sensitive(FALSE);


	#--------------------------------------

	#handle profiles
	#--------------------------------------
	my $combobox_settings_profiles = Gtk2::ComboBox->new_text;
	my @current_profiles;
	my $current_index = 0;
	foreach ( sort glob("$ENV{'HOME'}/.shutter/profiles/*.xml") ) {
		utf8::decode $_;
		next if $_ =~ /\_accounts.xml/;    #accounts file - we are looking for "real" profiles
		$_ =~ /.*\/(.*)\.xml/;            #get profiles name
		my $last_profile_name = $1;
		$combobox_settings_profiles->append_text($last_profile_name);

		#set active profile
		if ( exists $settings_xml->{'general'}->{'last_profile_name'} ) {
			if ( $settings_xml->{'general'}->{'last_profile_name'} eq $last_profile_name ) {
				$combobox_settings_profiles->set_active($current_index);
				$current_profile_indx = $current_index;
			}
		}

		push( @current_profiles, $last_profile_name );
		$current_index++;
	}
	$tooltips->set_tip( $combobox_settings_profiles, $d->get("Choose a profile") );

	#set 0 if nothing is selected yet
	if ( !$combobox_settings_profiles->get_active_text ) {
		$combobox_settings_profiles->set_active(0);
		$current_profile_indx = 0;
	}

	#populate quick selector as well
	&fct_update_profile_selectors($combobox_settings_profiles, \@current_profiles);

	my $button_profile_save = Gtk2::Button->new;
	$button_profile_save->signal_connect(
		'clicked' => sub {
			my $widget = shift;
			&evt_save_profile( $widget, $combobox_settings_profiles, \@current_profiles );
		}
	);
	$button_profile_save->set_image( Gtk2::Image->new_from_stock( 'gtk-save', 'button' ) );
	$tooltips->set_tip( $button_profile_save, $d->get("Save configuration as profile") );

	my $button_profile_delete = Gtk2::Button->new;
	$button_profile_delete->signal_connect(
		'clicked' => sub {
			my $widget = shift;
			&evt_delete_profile( $widget, $combobox_settings_profiles, \@current_profiles );
		}
	);
	$button_profile_delete->set_image( Gtk2::Image->new_from_stock( 'gtk-delete', 'button' ) );
	$tooltips->set_tip( $button_profile_delete, $d->get("Delete profile") );
	my $button_profile_apply = Gtk2::Button->new;
	$button_profile_apply->signal_connect(
		'clicked' => sub {
			my $widget = shift;
			&evt_apply_profile( $widget, $combobox_settings_profiles, \@current_profiles );
		}
	);
	$button_profile_apply->set_image( Gtk2::Image->new_from_stock( 'gtk-apply', 'button' ) );
	$tooltips->set_tip( $button_profile_apply, $d->get("Load the selected profile's configuration") );

	#--------------------------------------


	#frames and label for settings dialog
	#--------------------------------------
	my $file_frame_label = Gtk2::Label->new;
	$file_frame_label->set_markup( "<b>" . $d->get("Image format") . "</b>" );

	my $file_frame = Gtk2::Frame->new();
	$file_frame->set_label_widget($file_frame_label);
	$file_frame->set_shadow_type('none');

	my $save_frame_label = Gtk2::Label->new;
	$save_frame_label->set_markup( "<b>" . $d->get("Save") . "</b>" );

	my $save_frame = Gtk2::Frame->new();
	$save_frame->set_label_widget($save_frame_label);
	$save_frame->set_shadow_type('none');

	my $window_frame_label = Gtk2::Label->new;
	$window_frame_label->set_markup( "<b>" . $d->get("Window Preferences") . "</b>" );

	my $window_frame = Gtk2::Frame->new();
	$window_frame->set_label_widget($window_frame_label);
	$window_frame->set_shadow_type('none');

	my $notify_frame_label = Gtk2::Label->new;
	$notify_frame_label->set_markup( "<b>" . $d->get("Notifications") . "</b>" );

	my $notify_frame = Gtk2::Frame->new();
	$notify_frame->set_label_widget($notify_frame_label);
	$notify_frame->set_shadow_type('none');

	my $trash_frame_label = Gtk2::Label->new;
	$trash_frame_label->set_markup( "<b>" . $d->get("Trash") . "</b>" );

	my $trash_frame = Gtk2::Frame->new();
	$trash_frame->set_label_widget($trash_frame_label);
	$trash_frame->set_shadow_type('none');

	my $keybinding_frame_label = Gtk2::Label->new;
	$keybinding_frame_label->set_markup( "<b>" . $d->get("Gnome-Keybinding") . "</b>" );

	my $keybinding_frame = Gtk2::Frame->new();
	$keybinding_frame->set_label_widget($keybinding_frame_label);
	$keybinding_frame->set_shadow_type('none');

	my $actions_frame_label = Gtk2::Label->new;
	$actions_frame_label->set_markup( "<b>" . $d->get("Actions") . "</b>" );

	my $actions_frame = Gtk2::Frame->new();
	$actions_frame->set_label_widget($actions_frame_label);
	$actions_frame->set_shadow_type('none');

	my $capture_frame_label = Gtk2::Label->new;
	$capture_frame_label->set_markup( "<b>" . $d->get("Capture") . "</b>" );

	my $capture_frame = Gtk2::Frame->new();
	$capture_frame->set_label_widget($capture_frame_label);
	$capture_frame->set_shadow_type('none');

	my $sel_capture_frame_label = Gtk2::Label->new;
	$sel_capture_frame_label->set_markup( "<b>" . $d->get("Selection Capture") . "</b>" );

	my $sel_capture_frame = Gtk2::Frame->new();
	$sel_capture_frame->set_label_widget($sel_capture_frame_label);
	$sel_capture_frame->set_shadow_type('none');

	my $asel_capture_frame_label = Gtk2::Label->new;
	$asel_capture_frame_label->set_markup( "<b>" . $d->get("Advanced Selection Capture") . "</b>" );

	my $asel_capture_frame = Gtk2::Frame->new();
	$asel_capture_frame->set_label_widget($asel_capture_frame_label);
	$asel_capture_frame->set_shadow_type('none');

	my $window_capture_frame_label = Gtk2::Label->new;
	$window_capture_frame_label->set_markup( "<b>" . $d->get("Window Capture") . "</b>" );

	my $window_capture_frame = Gtk2::Frame->new();
	$window_capture_frame->set_label_widget($window_capture_frame_label);
	$window_capture_frame->set_shadow_type('none');

	my $menu_capture_frame_label = Gtk2::Label->new;
	$menu_capture_frame_label->set_markup( "<b>" . $d->get("Menu/Tooltip Capture") . "</b>" );

	my $menu_capture_frame = Gtk2::Frame->new();
	$menu_capture_frame->set_label_widget($menu_capture_frame_label);
	$menu_capture_frame->set_shadow_type('none');

	my $web_capture_frame_label = Gtk2::Label->new;
	$web_capture_frame_label->set_markup( "<b>" . $d->get("Website Capture") . "</b>" );

	my $web_capture_frame = Gtk2::Frame->new();
	$web_capture_frame->set_label_widget($web_capture_frame_label);
	$web_capture_frame->set_shadow_type('none');

	my $accounts_frame_label = Gtk2::Label->new;
	$accounts_frame_label->set_markup( "<b>" . $d->get("Accounts") . "</b>" );

	my $accounts_frame = Gtk2::Frame->new();
	$accounts_frame->set_label_widget($accounts_frame_label);
	$accounts_frame->set_shadow_type('none');

	my $ftp_frame_label = Gtk2::Label->new;
	$ftp_frame_label->set_markup( "<b>" . $d->get("File Transfer Protocol (FTP)") . "</b>" );

	my $ftp_frame = Gtk2::Frame->new();
	$ftp_frame->set_label_widget($ftp_frame_label);
	$ftp_frame->set_shadow_type('none');

	my $transparent_frame_label = Gtk2::Label->new;
	$transparent_frame_label->set_markup( "<b>" . $d->get("Transparent Parts") . "</b>" );

	my $transparent_frame = Gtk2::Frame->new();
	$transparent_frame->set_label_widget($transparent_frame_label);
	$transparent_frame->set_shadow_type('none');

	#filename
	#--------------------------------------
	my $filename_label = Gtk2::Label->new( $d->get("Filename") . ":" );

	my $filename = Gtk2::Entry->new;
	if ( defined $settings_xml->{'general'}->{'filename'} ) {
		$filename->set_text( $settings_xml->{'general'}->{'filename'} );
	} else {
		$filename->set_text("\$name_\%NNN");
	}

	#do some input validation
	#here are all invalid char codes
	my @invalid_codes = (47,92,63,42,58,124,34,60,62,44,59,35,38);
	my $filename_hint = Gtk2::Label->new;
	$filename_hint->set_no_show_all(TRUE);
	$filename->signal_connect('key-press-event' => sub {
		my $filename 	= shift;
		my $event 		= shift;
		
		my $input = Gtk2::Gdk->keyval_to_unicode ($event->keyval); 
		
		#invalid input
		#~ print $input."\n";
		if(grep($input == $_, @invalid_codes)){
			my $char = chr($input);
			$char = '&amp;' if $char eq '&';
			$filename_hint->set_markup("<span size='small'>" . 
											sprintf($d->get("Reserved character %s is not allowed to be in a filename.") , "'".$char."'") 
											. "</span>");	
			
			$filename_hint->show;
			return TRUE;
		}else{
			#clear possible message when valid char is entered
			$filename_hint->set_markup("<span size='small'></span>");						
			$filename_hint->hide;
			return FALSE;
		}
	});

	my $filename_tooltip_string = 	
		$d->get("There are several wildcards available, like\n").
		$d->get("%Y = year\n").
		$d->get("%m = month\n").
		$d->get("%d = day\n").
		$d->get("%T = time\n").
		$d->get("\$w = width\n").
		$d->get("\$h = height\n").
		$d->get("\$name = multi-purpose (e.g. window title)\n").
		$d->get("\$nb_name = like \$name but without blanks in resulting strings\n").
		$d->get("\$profile = name of current profile\n").
		$d->get("\$R = random char (e.g. \$RRRR = ag4r)\n").
		$d->get("%NN = counter");

	$tooltips->set_tip($filename, $filename_tooltip_string);
	$tooltips->set_tip($filename_label, $filename_tooltip_string);

	$filename_box->pack_start( $filename_label, FALSE, TRUE, 12 );
	$filename_box->pack_start( $filename,       TRUE,  TRUE, 0 );

	#end - filename
	#--------------------------------------


	#filetype and scale
	#--------------------------------------
	my $scale = Gtk2::HScale->new_with_range( 0, 9, 1 );
	my $scale_label = Gtk2::Label->new( $d->get("Compression") . ":" );
	$scale->set_value_pos('right');
	$scale->set_value(1);

	#we don't need a default here because it will be set through signal handling (filetype)
	if ( defined $settings_xml->{'general'}->{'quality'} ) {
		$scale->set_value( $settings_xml->{'general'}->{'quality'} );
	}

	$tooltips->set_tip( $scale,
		$d->get("Quality/Compression:\nHigh value means high size / high compression\n(depending on file format chosen)") );
	$tooltips->set_tip( $scale_label,
		$d->get("Quality/Compression:\nHigh value means high size / high compression\n(depending on file format chosen)") );
	$scale_box->pack_start( $scale_label, FALSE, TRUE, 12 );
	$scale_box->pack_start( $scale, TRUE, TRUE, 0 );

	#add compatile, writeable file types
	my $combobox_type = Gtk2::ComboBox->new_text;
	my ( $int_png, $int_jpeg, $int_bmp ) = ( -1, -1, -1 );
	my $format_counter = 0;

	foreach ( Gtk2::Gdk::Pixbuf->get_formats ) {
		if (   $_->{name} eq "jpeg"
			|| $_->{name} eq "png"
			|| $_->{name} eq "bmp" )
		{
			$combobox_type->append_text( $_->{name} . " - " . $_->{description} );
			
			#a little ugly here, maybe the values are in alternative order on several machine...
			#just remember the number when appending, so we can set png as default for example
			if ( $_->{name} eq "jpeg" ) {
				$int_jpeg = $format_counter;
			} elsif ( $_->{name} eq "png" ) {
				$int_png = $format_counter;
			} elsif ( $_->{name} eq "bmp" ) {
				$int_bmp = $format_counter;
			}

			$format_counter++;

		}
	}
	$combobox_type->signal_connect( 'changed' => \&evt_value_changed, 'type_changed' );
	$scale->signal_connect( 'value-changed' => \&evt_value_changed, 'qvalue_changed' );

	if ( defined $settings_xml->{'general'}->{'filetype'} ) {
		
		#migration from gscrot to shutter
		#maybe we can drop this in future releases
		# 0 := jpeg
		# 1 := png
		unless(defined $settings_xml->{'general'}->{'app_version'}){
			if($settings_xml->{'general'}->{'filetype'} == 0){
				$combobox_type->set_active($int_jpeg);			
			}elsif($settings_xml->{'general'}->{'filetype'} == 1){
				$combobox_type->set_active($int_png);		
			}
		
		#shutter
		}else{
			$combobox_type->set_active($settings_xml->{'general'}->{'filetype'});	
		}
		
		#set saved quality/compression value if there is one
		if(defined $settings_xml->{'general'}->{'quality'}){
			$scale->set_value( $settings_xml->{'general'}->{'quality'} );		
		} 

	} else {

		#we will try to set a default value in this order
		foreach ( @{ [ $int_png, $int_jpeg, $int_bmp ] } ) {
			if ( $_ > -1 ) {
				$combobox_type->set_active( $_ );
				last;
			}
		}

	}

	my $filetype_label = Gtk2::Label->new( $d->get("Image format") . ":" );
	$tooltips->set_tip( $combobox_type,  $d->get("Select a file format") );
	$tooltips->set_tip( $filetype_label, $d->get("Select a file format") );
	$filetype_box->pack_start( $filetype_label, FALSE, TRUE, 12 );
	$filetype_box->pack_start( $combobox_type,  TRUE,  TRUE, 0 );

	#end - filetype and scale
	#--------------------------------------

	#saveDir
	#--------------------------------------
	my $saveDir_label = Gtk2::Label->new( $d->get("Directory") . ":" );
	my $saveDir_button = Gtk2::FileChooserButton->new( "Shutter - " . $d->get("Choose folder"), 'select-folder' );
	if ( defined $settings_xml->{'general'}->{'folder'} ) {
		$saveDir_button->set_current_folder( $settings_xml->{'general'}->{'folder'} );
	} else {
		$saveDir_button->set_current_folder( File::HomeDir->my_pictures );
	}

	$tooltips->set_tip( $saveDir_button, $d->get("Your screenshots will be saved to this directory") );
	$tooltips->set_tip( $saveDir_label,  $d->get("Your screenshots will be saved to this directory") );
	$saveDir_box->pack_start( $saveDir_label,  FALSE, TRUE, 12 );
	$saveDir_box->pack_start( $saveDir_button, TRUE,  TRUE, 0 );

	#end - saveDir
	#--------------------------------------

	#save options
	#--------------------------------------
	my $save_ask_active = Gtk2::RadioButton->new_with_label(undef, $d->get("Browse for save folder every time") );
	$save_ask_box->pack_start( $save_ask_active, FALSE, TRUE, 12 );

	$tooltips->set_tip( $save_ask_active, $d->get("Browse for save folder every time") );

	my $save_auto_active = Gtk2::RadioButton->new_with_label($save_ask_active, $d->get("Automatically save file") );
	$save_auto_box->pack_start( $save_auto_active, FALSE, TRUE, 12 );

	$tooltips->set_tip( $save_auto_active, $d->get("Automatically save file") );

	$save_ask_active->signal_connect(
		'toggled' => \&evt_value_changed,
		'save_toggled'
	);

	$save_auto_active->signal_connect(
		'toggled' => \&evt_value_changed,
		'save_toggled'
	);

	#default state
	$save_ask_active->set_active( FALSE );
	$save_auto_active->set_active( TRUE );

	if ( defined $settings_xml->{'general'}->{'save_auto'} ) {
		$save_auto_active->set_active( $settings_xml->{'general'}->{'save_auto'} );
	}

	if ( defined $settings_xml->{'general'}->{'save_ask'} ) {
		$save_ask_active->set_active( $settings_xml->{'general'}->{'save_ask'} );
	}

	#end - save options
	#--------------------------------------

	#image_autocopy
	#--------------------------------------
	my $image_autocopy_active = Gtk2::RadioButton->new_with_label(undef, $d->get("Automatically copy screenshot to clipboard") );
	$image_autocopy_box->pack_start( $image_autocopy_active, FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'image_autocopy'} ) {
		$image_autocopy_active->set_active( $settings_xml->{'general'}->{'image_autocopy'} );
	} else {
		$image_autocopy_active->set_active(TRUE);
	}

	$tooltips->set_tip( $image_autocopy_active, $d->get("Automatically copy screenshot to clipboard") );

	#end - image_autocopy
	#--------------------------------------

	#fname_autocopy
	#--------------------------------------
	my $fname_autocopy_active = Gtk2::RadioButton->new_with_label($image_autocopy_active, $d->get("Automatically copy filename to clipboard") );
	$fname_autocopy_box->pack_start( $fname_autocopy_active, FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'fname_autocopy'} ) {
		$fname_autocopy_active->set_active( $settings_xml->{'general'}->{'fname_autocopy'} );
	} else {
		$fname_autocopy_active->set_active(FALSE);
	}

	$tooltips->set_tip( $fname_autocopy_active, $d->get("Automatically copy filename to clipboard") );

	#end - fname_autocopy
	#--------------------------------------

	#no_autocopy
	#--------------------------------------
	my $no_autocopy_active = Gtk2::RadioButton->new_with_label($image_autocopy_active, $d->get("Do not copy anything to clipboard") );
	$no_autocopy_box->pack_start( $no_autocopy_active, FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'no_autocopy'} ) {
		$no_autocopy_active->set_active( $settings_xml->{'general'}->{'no_autocopy'} );
	} else {
		$no_autocopy_active->set_active(FALSE);
	}

	$tooltips->set_tip( $no_autocopy_active, $d->get("Do not copy anything to clipboard") );

	#end - no_autocopy
	#--------------------------------------

	#delay
	#--------------------------------------

	#delay statusbar
	my $delay_status_label = Gtk2::Label->new( $d->get("Delay") .":" );
	my $delay_status = Gtk2::SpinButton->new_with_range( 0, 99, 1 );
	my $delay_status_vlabel = Gtk2::Label->new( $d->nget("second", "seconds", $delay_status->get_value) );
	$delay_status->signal_connect(
		'value-changed' => \&evt_value_changed,
		'delay_status_changed'
	);

	#delay settings dialog
	my $delay_label = Gtk2::Label->new( $d->get("Capture after a delay of") );
	my $delay = Gtk2::SpinButton->new_with_range( 0, 99, 1 );
	my $delay_vlabel = Gtk2::Label->new( $d->nget("second", "seconds", $delay->get_value) );
	$delay->signal_connect(
		'value-changed' => \&evt_value_changed,
		'delay_changed'
	);

	if ( defined $settings_xml->{'general'}->{'delay'} ) {
		$delay->set_value( $settings_xml->{'general'}->{'delay'} );
	} else {
		$delay->set_value(0);
	}

	$tooltips->set_tip( $delay, $d->get("Wait n seconds before taking a screenshot") );
	$tooltips->set_tip( $delay_label, $d->get("Wait n seconds before taking a screenshot") );
	$tooltips->set_tip( $delay_vlabel, $d->get("Wait n seconds before taking a screenshot") );

	$tooltips->set_tip( $delay_status, $d->get("Wait n seconds before taking a screenshot") );
	$tooltips->set_tip( $delay_status_label, $d->get("Wait n seconds before taking a screenshot") );
	$tooltips->set_tip( $delay_status_vlabel, $d->get("Wait n seconds before taking a screenshot") );

	$delay_box->pack_start( $delay_label, FALSE, FALSE, 12 );
	$delay_box->pack_start( $delay, FALSE, FALSE, 0 );
	$delay_box->pack_start( $delay_vlabel, FALSE, FALSE, 2 );

	#end - delay
	#--------------------------------------

	#cursor
	#--------------------------------------
	my $cursor_status_active = Gtk2::CheckButton->new_with_label( $d->get("Include Cursor") );
	$tooltips->set_tip( $cursor_status_active, $d->get("Include cursor when taking a screenshot") );
	$cursor_status_active->signal_connect(
		'toggled' => \&evt_value_changed,
		'cursor_status_toggled'
	);

	my $cursor_active = Gtk2::CheckButton->new_with_label( $d->get("Include cursor when taking a screenshot") );
	$tooltips->set_tip( $cursor_active, $d->get("Include cursor when taking a screenshot") );
	$cursor_active->signal_connect(
		'toggled' => \&evt_value_changed,
		'cursor_toggled'
	);

	$cursor_box->pack_start( $cursor_active,    FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'cursor'} ) {
		$cursor_active->set_active( $settings_xml->{'general'}->{'cursor'} );
	} else {
		$cursor_active->set_active(TRUE);
	}

	#end - cursor
	#--------------------------------------

	#program
	#--------------------------------------
	my $model		= &fct_get_program_model;
	my $progname	= Gtk2::ComboBox->new($model);

	#add pixbuf renderer for icon
	my $renderer_pix = Gtk2::CellRendererPixbuf->new;
	$progname->pack_start( $renderer_pix, FALSE );
	$progname->add_attribute( $renderer_pix, pixbuf => 0 );

	#add text renderer for app name
	my $renderer_text = Gtk2::CellRendererText->new;
	$progname->pack_start( $renderer_text, FALSE );
	$progname->add_attribute( $renderer_text, text => 1 );

	#try to set the saved value
	if ( defined $settings_xml->{'general'}->{'prog'} ) {
		$model->foreach( \&fct_iter_programs, $settings_xml->{'general'}->{'prog'} );
	} else {
		$progname->set_active(0);
	}

	#nothing has been set
	if ( $progname->get_active == -1 ) {
		$progname->set_active(0);
	}

	my $progname_active = Gtk2::CheckButton->new;
	$progname_active->set_active(TRUE);
	$progname_active->signal_connect(
		'toggled' => \&evt_value_changed,
		'progname_toggled'
	);
	if ( defined $settings_xml->{'general'}->{'prog_active'} ) {
		$progname_active->set_active( $settings_xml->{'general'}->{'prog_active'} );
	} else {
		$progname_active->set_active(FALSE);
	}
	my $progname_label = Gtk2::Label->new( $d->get("Open with") . ":" );
	$tooltips->set_tip( $progname,        $d->get("Open your screenshot with this program after capturing") );
	$tooltips->set_tip( $progname_active, $d->get("Open your screenshot with this program after capturing") );
	$tooltips->set_tip( $progname_label,  $d->get("Open your screenshot with this program after capturing") );
	$progname_box->pack_start( $progname_label, FALSE, TRUE, 12 );
	$progname_box->pack_start( $progname_active, FALSE, TRUE, 0 );
	$progname_box->pack_start( $progname, TRUE, TRUE, 0 );

	#end - program
	#--------------------------------------

	#im_colors
	#--------------------------------------
	my $combobox_im_colors = Gtk2::ComboBox->new_text;
	$combobox_im_colors->insert_text( 0, $d->get("16 colors   - (4bit) ") );
	$combobox_im_colors->insert_text( 1, $d->get("64 colors   - (6bit) ") );
	$combobox_im_colors->insert_text( 2, $d->get("256 colors  - (8bit) ") );
	$combobox_im_colors->signal_connect(
		'changed' => \&evt_value_changed,
		'im_colors_changed'
	);

	if ( defined $settings_xml->{'general'}->{'im_colors'} ) {
		$combobox_im_colors->set_active( $settings_xml->{'general'}->{'im_colors'} );
	} else {
		$combobox_im_colors->set_active(2);
	}

	my $im_colors_active = Gtk2::CheckButton->new;
	$im_colors_active->set_active(TRUE);
	$im_colors_active->signal_connect(
		'toggled' => \&evt_value_changed,
		'im_colors_toggled'
	);

	if ( defined $settings_xml->{'general'}->{'im_colors_active'} ) {
		$im_colors_active->set_active( $settings_xml->{'general'}->{'im_colors_active'} );
	} else {
		$im_colors_active->set_active(FALSE);
	}

	my $im_colors_label = Gtk2::Label->new( $d->get("Reduce colors") . ":" );
	$tooltips->set_tip( $combobox_im_colors, $d->get("Automatically reduce colors after taking a screenshot") );
	$tooltips->set_tip( $im_colors_active,   $d->get("Automatically reduce colors after taking a screenshot") );
	$tooltips->set_tip( $im_colors_label,    $d->get("Automatically reduce colors after taking a screenshot") );
	$im_colors_box->pack_start( $im_colors_label, FALSE, TRUE, 12 );
	$im_colors_box->pack_start( $im_colors_active,   FALSE, TRUE, 0 );
	$im_colors_box->pack_start( $combobox_im_colors, TRUE,  TRUE, 0 );

	#end - colors
	#--------------------------------------

	#thumbnail
	#--------------------------------------
	my $thumbnail_label = Gtk2::Label->new( $d->get("Thumbnail") . ":" );
	my $thumbnail = Gtk2::HScale->new_with_range( 1, 100, 1 );
	$thumbnail->signal_connect(
		'value-changed' => \&evt_value_changed,
		'thumbnail_changed'
	);
	$thumbnail->set_value_pos('right');

	if ( defined $settings_xml->{'general'}->{'thumbnail'} ) {
		$thumbnail->set_value( $settings_xml->{'general'}->{'thumbnail'} );
	} else {
		$thumbnail->set_value(50);
	}
	my $thumbnail_active = Gtk2::CheckButton->new;
	$thumbnail_active->set_active(TRUE);
	$thumbnail_active->signal_connect(
		'toggled' => \&evt_value_changed,
		'thumbnail_toggled'
	);

	if ( defined $settings_xml->{'general'}->{'thumbnail_active'} ) {
		$thumbnail_active->set_active( $settings_xml->{'general'}->{'thumbnail_active'} );
	} else {
		$thumbnail_active->set_active(FALSE);
	}
	$tooltips->set_tip( $thumbnail,
		$d->get("Generate thumbnail too.\nselect the percentage of the original size for the thumbnail to be") );
	$tooltips->set_tip( $thumbnail_active,
		$d->get("Generate thumbnail too.\nselect the percentage of the original size for the thumbnail to be") );
	$tooltips->set_tip( $thumbnail_label,
		$d->get("Generate thumbnail too.\nselect the percentage of the original size for the thumbnail to be") );
	$thumbnail_box->pack_start( $thumbnail_label, FALSE, TRUE, 12 );
	$thumbnail_box->pack_start( $thumbnail_active, FALSE, FALSE, 0 );
	$thumbnail_box->pack_start( $thumbnail,        TRUE,  TRUE,  0 );

	#end - thumbnail
	#--------------------------------------

	#bordereffect
	#--------------------------------------
	my $bordereffect_active = Gtk2::CheckButton->new;
	$bordereffect_active->set_active(TRUE);

	my $bordereffect_label = Gtk2::Label->new( $d->get("Border") . ":" );
	my $bordereffect = Gtk2::SpinButton->new_with_range( 1, 100, 1 );
	my $bordereffect_vlabel = Gtk2::Label->new( $d->get("pixels") );

	my $bordereffect_clabel = Gtk2::Label->new( $d->get("Color") . ":" );
	my $bordereffect_cbtn = Gtk2::ColorButton->new();
	$bordereffect_cbtn->set_use_alpha(FALSE);
	$bordereffect_cbtn->set_title( $d->get("Choose border color") );

	$tooltips->set_tip( $bordereffect_active,
		$d->get("Adds a border effect to the screenshot") );
	$tooltips->set_tip( $bordereffect,
		$d->get("Adds a border effect to the screenshot") );
	$tooltips->set_tip( $bordereffect_label,
		$d->get("Adds a border effect to the screenshot") );

	$tooltips->set_tip( $bordereffect_clabel,
		$d->get("Choose border color") );
	$tooltips->set_tip( $bordereffect_cbtn,
		$d->get("Choose border color") );	
		
	$bordereffect_box->pack_start( $bordereffect_label, FALSE, TRUE, 12 );
	$bordereffect_box->pack_start( $bordereffect_active, FALSE, FALSE, 0 );
	$bordereffect_box->pack_start( $bordereffect, TRUE, TRUE, 2 );
	$bordereffect_box->pack_start( $bordereffect_vlabel, FALSE, FALSE, 2 );
	$bordereffect_box->pack_start( $bordereffect_clabel, FALSE, FALSE, 12 );
	$bordereffect_box->pack_start( $bordereffect_cbtn, FALSE, FALSE, 0 );

	$bordereffect_active->signal_connect(
		'toggled' => \&evt_value_changed,
		'bordereffect_toggled'
	);

	$bordereffect->signal_connect(
		'value-changed' => \&evt_value_changed,
		'bordereffect_changed'
	);

	if ( defined $settings_xml->{'general'}->{'bordereffect_active'} ) {
		$bordereffect_active->set_active( $settings_xml->{'general'}->{'bordereffect_active'} );
	} else {
		$bordereffect_active->set_active(FALSE);
	}

	if ( defined $settings_xml->{'general'}->{'bordereffect'} ) {
		$bordereffect->set_value( $settings_xml->{'general'}->{'bordereffect'} );
	} else {
		$bordereffect->set_value(2);
	}

	if ( defined $settings_xml->{'general'}->{'bordereffect_col'} ){
		$bordereffect_cbtn->set_color(Gtk2::Gdk::Color->parse($settings_xml->{'general'}->{'bordereffect_col'}));
	} else {
		$bordereffect_cbtn->set_color( Gtk2::Gdk::Color->parse('black') );		
	}

	#end - bordereffect
	#--------------------------------------

	#zoom window
	#--------------------------------------
	my $zoom_active = Gtk2::CheckButton->new_with_label( $d->get("Enable zoom window") );

	if ( defined $settings_xml->{'general'}->{'zoom_active'} ) {
		$zoom_active->set_active( $settings_xml->{'general'}->{'zoom_active'} );
	} else {
		$zoom_active->set_active(TRUE);
	}

	$tooltips->set_tip( $zoom_active, $d->get("Enable zoom window") );

	$zoom_box->pack_start( $zoom_active, FALSE, TRUE, 12 );

	#end - zoom window
	#--------------------------------------

	#initial size for advanced selection tool
	#--------------------------------------
	my $asel_size_label1 = Gtk2::Label->new( $d->get("Start with selection size of") );
	my $asel_size_label2 = Gtk2::Label->new( "x" );
	my $asel_size_label3 = Gtk2::Label->new( $d->get("at") );
	my $asel_size_label4 = Gtk2::Label->new( "," );
	my $asel_size1 = Gtk2::SpinButton->new_with_range( 0, 10000, 1 );
	my $asel_size2 = Gtk2::SpinButton->new_with_range( 0, 10000, 1 );
	my $asel_size3 = Gtk2::SpinButton->new_with_range( 0, 10000, 1 );
	my $asel_size4 = Gtk2::SpinButton->new_with_range( 0, 10000, 1 );
	my $asel_size_vlabel1 = Gtk2::Label->new( $d->get("pixels") );
	my $asel_size_vlabel2 = Gtk2::Label->new( $d->get("pixels") );

	if ( defined $settings_xml->{'general'}->{'asel_x'} ) {
		$asel_size3->set_value($settings_xml->{'general'}->{'asel_x'});
	} else {
		$asel_size3->set_value(0);
	}
	if ( defined $settings_xml->{'general'}->{'asel_y'} ) {
		$asel_size4->set_value($settings_xml->{'general'}->{'asel_y'});
	} else {
		$asel_size4->set_value(0);
	}
	if ( defined $settings_xml->{'general'}->{'asel_w'} ) {
		$asel_size1->set_value($settings_xml->{'general'}->{'asel_w'});
	} else {
		$asel_size1->set_value(0);
	}
	if ( defined $settings_xml->{'general'}->{'asel_h'} ) {
		$asel_size2->set_value($settings_xml->{'general'}->{'asel_h'});
	} else {
		$asel_size2->set_value(0);
	}

	$tooltips->set_tip( $asel_size_label1, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size_label2, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size_label3, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size_label4, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size1, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size2, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size3, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size4, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size_vlabel1, $d->get("Start Advanced Selection Tool with a customized selection size") );
	$tooltips->set_tip( $asel_size_vlabel2, $d->get("Start Advanced Selection Tool with a customized selection size") );

	$asel_isize_box->pack_start( $asel_size_label1, FALSE, FALSE, 12 );
	$asel_isize_box->pack_start( $asel_size1, FALSE, FALSE,  0 );
	$asel_isize_box->pack_start( $asel_size_label2, FALSE, FALSE,  0 );
	$asel_isize_box->pack_start( $asel_size2, FALSE, FALSE,  0 );
	$asel_isize_box->pack_start( $asel_size_vlabel1, FALSE, FALSE,  2 );
	$asel_isize_box2->pack_start( $asel_size_label3, FALSE, FALSE,  12 );
	$asel_isize_box2->pack_start( $asel_size3, FALSE, FALSE,  0 );
	$asel_isize_box2->pack_start( $asel_size_label4, FALSE, FALSE,  0 );
	$asel_isize_box2->pack_start( $asel_size4, FALSE, FALSE,  0 );
	$asel_isize_box2->pack_start( $asel_size_vlabel2, FALSE, FALSE, 2 );

	#end - initial size for advanced selection tool
	#--------------------------------------

	#show help text when using advanced selection tool
	#--------------------------------------
	my $as_help_active = Gtk2::CheckButton->new_with_label( $d->get("Show help text") );

	if ( defined $settings_xml->{'general'}->{'as_help_active'} ) {
		$as_help_active->set_active( $settings_xml->{'general'}->{'as_help_active'} );
	} else {
		$as_help_active->set_active(TRUE);
	}

	$tooltips->set_tip( $as_help_active, $d->get("Enables the help text") );

	$as_help_box->pack_start( $as_help_active, FALSE, TRUE, 12 );

	#end - show help text when using advanced selection tool
	#--------------------------------------

	#border
	#--------------------------------------
	my $border_active = Gtk2::CheckButton->new_with_label( $d->get("Include window decoration when capturing a window") );
	$tooltips->set_tip( $border_active, $d->get("Include window decoration when capturing a window") );

	$border_box->pack_start( $border_active, FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'border'} ) {
		$border_active->set_active( $settings_xml->{'general'}->{'border'} );
	} else {
		$border_active->set_active(TRUE);
	}

	#end - border
	#--------------------------------------

	#visible windows only
	#--------------------------------------
	my $visible_windows_active = Gtk2::CheckButton->new_with_label( $d->get("Select only visible windows") );
	$tooltips->set_tip( $visible_windows_active, $d->get("Select only visible windows") );

	$visible_windows_box->pack_start( $visible_windows_active, FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'visible_windows'} ) {
		$visible_windows_active->set_active( $settings_xml->{'general'}->{'visible_windows'} );
	} else {
		$visible_windows_active->set_active(FALSE);
	}

	#end - visible windows only
	#--------------------------------------

	#menu capture delay
	#--------------------------------------
	#delay settings dialog
	my $menu_delay_label = Gtk2::Label->new( $d->get("Pre-Capture Delay") . ":" );
	my $menu_delay = Gtk2::SpinButton->new_with_range( 1, 99, 1 );
	my $menu_delay_vlabel = Gtk2::Label->new( $d->nget("second", "seconds", $delay->get_value) );
	$menu_delay->signal_connect(
		'value-changed' => \&evt_value_changed,
		'menu_delay_changed'
	);

	if ( defined $settings_xml->{'general'}->{'menu_delay'} ) {
		$menu_delay->set_value( $settings_xml->{'general'}->{'menu_delay'} );
	} else {
		$menu_delay->set_value(10);
	}

	$tooltips->set_tip( $menu_delay,        $d->get("Capture menu/tooltip after a delay of n seconds") );
	$tooltips->set_tip( $menu_delay_label,  $d->get("Capture menu/tooltip after a delay of n seconds") );
	$tooltips->set_tip( $menu_delay_vlabel, $d->get("Capture menu/tooltip after a delay of n seconds") );

	$menu_delay_box->pack_start( $menu_delay_label, FALSE, TRUE, 12 );
	$menu_delay_box->pack_start( $menu_delay, FALSE, TRUE,  0 );
	$menu_delay_box->pack_start( $menu_delay_vlabel, FALSE, TRUE, 2 );

	#end - menu capture delay
	#--------------------------------------

	#menu/tooltip workaround
	#--------------------------------------
	my $menu_waround_active = Gtk2::CheckButton->new_with_label( $d->get("Ignore possibly wrong type hints") );
	$tooltips->set_tip( $menu_waround_active, $d->get("The type hint constants specify hints for the window manager that indicate what type of function the window has. Sometimes these type hints are not correctly set. By enabling this option Shutter will not insist on the requested type hint.") );

	$menu_waround_box->pack_start( $menu_waround_active, FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'menu_waround'} ) {
		$menu_waround_active->set_active( $settings_xml->{'general'}->{'menu_waround'} );
	} else {
		$menu_waround_active->set_active(TRUE);
	}

	#end - menu/tooltip workaround
	#--------------------------------------

	#web width
	#--------------------------------------
	my $web_width_label = Gtk2::Label->new( $d->get("Virtual browser width") . ":" );
	my $combobox_web_width = Gtk2::ComboBox->new_text;
	$combobox_web_width->insert_text( 0, "640" );
	$combobox_web_width->insert_text( 1, "800" );
	$combobox_web_width->insert_text( 2, "1024" );
	$combobox_web_width->insert_text( 3, "1152" );
	$combobox_web_width->insert_text( 4, "1280" );
	$combobox_web_width->insert_text( 5, "1366" );
	$combobox_web_width->insert_text( 6, "1440" );
	$combobox_web_width->insert_text( 7, "1600" );
	$combobox_web_width->insert_text( 8, "1680" );
	$combobox_web_width->insert_text( 9, "1920" );
	$combobox_web_width->insert_text( 10, "2048" );
	my $web_width_vlabel = Gtk2::Label->new( $d->get("pixels") );

	if ( defined $settings_xml->{'general'}->{'web_width'} ) {
		$combobox_web_width->set_active( $settings_xml->{'general'}->{'web_width'} );
	} else {
		$combobox_web_width->set_active(2);
	}

	$tooltips->set_tip( $web_width_label,		$d->get("Virtual browser width when taking a website screenshot") );
	$tooltips->set_tip( $combobox_web_width,	$d->get("Virtual browser width when taking a website screenshot") );
	$tooltips->set_tip( $web_width_vlabel,		$d->get("Virtual browser width when taking a website screenshot") );

	$web_width_box->pack_start( $web_width_label, FALSE, TRUE, 12 );
	$web_width_box->pack_start( $combobox_web_width, FALSE, TRUE,  0 );
	$web_width_box->pack_start( $web_width_vlabel, FALSE, TRUE, 2 );

	#end - web width
	#--------------------------------------

	#imageview
	#--------------------------------------
	my $trans_check  = Gtk2::RadioButton->new (undef, $d->get("Show as check pattern"));
	my $trans_custom = Gtk2::RadioButton->new ($trans_check, $d->get("Show as custom color:"));
	my $trans_custom_btn = Gtk2::ColorButton->new();
	$trans_custom_btn->set_use_alpha(FALSE);
	$trans_custom_btn->set_title( $d->get("Choose fill color") );

	my $trans_backg  = Gtk2::RadioButton->new ($trans_custom, $d->get("Show as background"));

	$imageview_hbox1->pack_start( $trans_check, FALSE, TRUE, 12 );
	$imageview_hbox2->pack_start( $trans_custom, FALSE, TRUE, 12 );
	$imageview_hbox2->pack_start( $trans_custom_btn, FALSE, TRUE, 0 );
	$imageview_hbox3->pack_start( $trans_backg, FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'trans_custom_col'} ){
		$trans_custom_btn->set_color(Gtk2::Gdk::Color->parse($settings_xml->{'general'}->{'trans_custom_col'}));
	} else {
		$trans_custom_btn->set_color( Gtk2::Gdk::Color->parse('black') );		
	}	

	if ( defined $settings_xml->{'general'}->{'trans_check'} && defined $settings_xml->{'general'}->{'trans_custom'} && defined $settings_xml->{'general'}->{'trans_backg'}) {
		$trans_check->set_active( $settings_xml->{'general'}->{'trans_check'} );
		$trans_custom->set_active( $settings_xml->{'general'}->{'trans_custom'} );
		$trans_backg->set_active( $settings_xml->{'general'}->{'trans_backg'} );
	} else {
		$trans_check->set_active(TRUE);
	}

	$tooltips->set_tip( $trans_check, $d->get("Displays any transparent parts of the image in a check pattern") );
	$tooltips->set_tip( $trans_custom, $d->get("Displays any transparent parts of the image in a solid color that you specify") );
	$tooltips->set_tip( $trans_backg, $d->get("Displays any transparent parts of the image in the background color of the application") );

	#connect signals after restoring the saved state
	$trans_check->signal_connect(
		'toggled' => \&evt_value_changed,
		'transp_toggled'
	);

	$trans_custom->signal_connect(
		'toggled' => \&evt_value_changed,
		'transp_toggled'
	);

	$trans_custom_btn->signal_connect(
		'color-set' => \&evt_value_changed,
		'transp_toggled'
	);

	$trans_backg->signal_connect(
		'toggled' => \&evt_value_changed,
		'transp_toggled'
	);

	#end - imageview
	#--------------------------------------

	#keybindings
	#--------------------------------------
	my $capture_key = Gtk2::Entry->new;
	if ( defined $settings_xml->{'general'}->{'capture_key'} ) {
		$capture_key->set_text( $settings_xml->{'general'}->{'capture_key'} );
	} else {
		$capture_key->set_text("Print");
	}
	my $capture_label = Gtk2::Label->new( $d->get("Capture") . ":" );
	$tooltips->set_tip(
		$capture_key,
		$d->get(
			"Configure global keybinding for capture\nThe format looks like \"<Control>a\" or \"<Shift><Alt>F1\". The parser is fairly liberal and allows lower or upper case, and also abbreviations such as \"<Ctl>\" and \"<Ctrl>\". If you set the option to the special string \"disabled\", then there will be no keybinding for this action. "
		)
	);
	$tooltips->set_tip(
		$capture_label,
		$d->get(
			"Configure global keybinding for capture\nThe format looks like \"<Control>a\" or \"<Shift><Alt>F1\". The parser is fairly liberal and allows lower or upper case, and also abbreviations such as \"<Ctl>\" and \"<Ctrl>\". If you set the option to the special string \"disabled\", then there will be no keybinding for this action. "
		)
	);
	my $capture_sel_key = Gtk2::Entry->new;
	if ( defined $settings_xml->{'general'}->{'capture_sel_key'} ) {
		$capture_sel_key->set_text( $settings_xml->{'general'}->{'capture_sel_key'} );
	} else {
		$capture_sel_key->set_text("<Alt>Print");
	}

	my $capture_sel_label = Gtk2::Label->new( $d->get("Capture with selection") . ":" );
	$tooltips->set_tip(
		$capture_sel_key,
		$d->get(
			"Configure global keybinding for capture with selection\nThe format looks like \"<Control>a\" or \"<Shift><Alt>F1\". The parser is fairly liberal and allows lower or upper case, and also abbreviations such as \"<Ctl>\" and \"<Ctrl>\". If you set the option to the special string \"disabled\", then there will be no keybinding for this action. "
		)
	);
	$tooltips->set_tip(
		$capture_sel_label,
		$d->get(
			"Configure global keybinding for capture with selection\nThe format looks like \"<Control>a\" or \"<Shift><Alt>F1\". The parser is fairly liberal and allows lower or upper case, and also abbreviations such as \"<Ctl>\" and \"<Ctrl>\". If you set the option to the special string \"disabled\", then there will be no keybinding for this action. "
		)
	);

	#keybinding_mode
	my $combobox_keybinding_mode = Gtk2::ComboBox->new_text;
	$combobox_keybinding_mode->insert_text( 0, $d->get("Selection") );
	$combobox_keybinding_mode->insert_text( 1, $d->get("Window") );
	$combobox_keybinding_mode->insert_text( 2, $d->get("Section") );

	if ( defined $settings_xml->{'general'}->{'keybinding_mode'} ) {
		$combobox_keybinding_mode->set_active( $settings_xml->{'general'}->{'keybinding_mode'} );
	} else {
		$combobox_keybinding_mode->set_active(1);
	}
	$tooltips->set_tip(
		$combobox_keybinding_mode,
		$d->get(
			"Configure global keybinding for capture with selection\nThe format looks like \"<Control>a\" or \"<Shift><Alt>F1\". The parser is fairly liberal and allows lower or upper case, and also abbreviations such as \"<Ctl>\" and \"<Ctrl>\". If you set the option to the special string \"disabled\", then there will be no keybinding for this action. "
		)
	);

	$keybinding_mode_box->pack_start( Gtk2::Label->new,          FALSE, FALSE, 0 );
	$keybinding_mode_box->pack_start( $combobox_keybinding_mode, TRUE,  TRUE,  0 );

	my $keybinding_active = Gtk2::CheckButton->new;
	my $keybinding_sel_active = Gtk2::CheckButton->new;

	$key_box->pack_start( $capture_label, FALSE, TRUE, 12 );
	$key_box->pack_start( $keybinding_active, FALSE, FALSE, 0 );
	$key_box->pack_start( $capture_key, TRUE,  TRUE,  0 );
	$key_sel_box->pack_start( $capture_sel_label, FALSE, TRUE, 12 );
	$key_sel_box->pack_start( $keybinding_sel_active, FALSE, FALSE, 0 );
	$key_sel_box->pack_start( $capture_sel_key,       TRUE,  TRUE,  0 );
	$keybinding_active->set_active(TRUE);

	#add signal handlers BEFORE settings are restored
	$keybinding_active->signal_connect(
		'toggled' => \&evt_behavior_handle,
		'keybinding_toggled'
	);

	$keybinding_sel_active->signal_connect(
		'toggled' => \&evt_behavior_handle,
		'keybinding_sel_toggled'
	);

	if ( defined $settings_xml->{'general'}->{'keybinding'} ) {
		$keybinding_active->set_active( $settings_xml->{'general'}->{'keybinding'} );
	} else {
		$keybinding_active->set_active(FALSE);
	}
	$keybinding_sel_active->set_active(TRUE);
	if ( defined $settings_xml->{'general'}->{'keybinding_sel'} ) {
		$keybinding_sel_active->set_active( $settings_xml->{'general'}->{'keybinding_sel'} );
	} else {
		$keybinding_sel_active->set_active(FALSE);
	}
	#end - keybindings
	#--------------------------------------

	#behavior
	#--------------------------------------
	my $hide_active           = Gtk2::CheckButton->new_with_label( $d->get("Autohide main window when taking a screenshot") );
	my $hide_time_label 	  = Gtk2::Label->new($d->get("Redraw Delay"). ":");
	my $hide_time_vlabel      = Gtk2::Label->new;
	my $hide_time			  = Gtk2::SpinButton->new_with_range (0, 1000, 50);
	$hide_time->signal_connect(
		'value-changed' => \&evt_value_changed,
		'hide_time_changed'
	);

	my $present_after_active  = Gtk2::CheckButton->new_with_label( $d->get("Present main window after taking a screenshot") );
	my $close_at_close_active = Gtk2::CheckButton->new_with_label( $d->get("Minimize to tray when closing main window") );

	my $notify_after_active    = Gtk2::CheckButton->new_with_label( $d->get("Display pop-up notification after taking a screenshot") );
	my $notify_timeout_active  = Gtk2::CheckButton->new_with_label( $d->get("Display pop-up notification when using a delay") );
	my $notify_ptimeout_active = Gtk2::CheckButton->new_with_label( $d->get("Display pop-up notification when using a pre-capture delay") );

	my $ns_label = Gtk2::Label->new( $d->get("Notification agent") . ":" );
	my $combobox_ns = Gtk2::ComboBox->new_text;
	$combobox_ns->append_text($d->get("Desktop Notifications"));
	$combobox_ns->append_text($d->get("Built-In Notifications"));

	$combobox_ns->signal_connect( 'changed' => \&evt_value_changed, 'ns_changed' );

	my $ask_on_delete_active    = Gtk2::CheckButton->new_with_label( $d->get("Ask before moving files to trash") );
	my $delete_on_close_active  = Gtk2::CheckButton->new_with_label( $d->get("Move file to trash when closing tab") );

	$hide_active_hbox->pack_start( $hide_active,            FALSE, TRUE, 12 );
	$pafter_active_hbox->pack_start( $present_after_active, FALSE, TRUE, 12 );
	$cac_hbox->pack_start( $close_at_close_active,          FALSE, TRUE, 12 );
	$hide_time_hbox->pack_start( $hide_time_label,          FALSE, TRUE, 12 );
	$hide_time_hbox->pack_start( $hide_time,                FALSE, TRUE,  6 );
	$hide_time_hbox->pack_start( $hide_time_vlabel,         FALSE, TRUE,  0 );
	$na_active_hbox->pack_start( $notify_after_active,      FALSE, TRUE, 12 );
	$nt_active_hbox->pack_start( $notify_timeout_active,    FALSE, TRUE, 12 );
	$npt_active_hbox->pack_start( $notify_ptimeout_active,  FALSE, TRUE, 12 );
	$ns_combo_hbox->pack_start( $ns_label,                  FALSE, TRUE, 12 );
	$ns_combo_hbox->pack_start( $combobox_ns,               FALSE, TRUE,  0 );
	$aod_active_hbox->pack_start( $ask_on_delete_active,    FALSE, TRUE, 12 );
	$doc_active_hbox->pack_start( $delete_on_close_active,  FALSE, TRUE, 12 );

	if ( defined $settings_xml->{'general'}->{'autohide'} ) {
		$hide_active->set_active( $settings_xml->{'general'}->{'autohide'} );
	} else {
		$hide_active->set_active(TRUE);
	}

	$tooltips->set_tip( $hide_active, $d->get("Autohide main window when taking a screenshot") );

	if ( defined $settings_xml->{'general'}->{'autohide_time'} ) {
		$hide_time->set_value( $settings_xml->{'general'}->{'autohide_time'} );
	} else {
		$hide_time->set_value(400);
	}

	$tooltips->set_tip( $hide_time_label, $d->get("Configure a short timeout to give the Xserver a chance to redraw areas that were obscured by Shutter's windows before taking a screenshot.") );
	$tooltips->set_tip( $hide_time, $d->get("Configure a short timeout to give the Xserver a chance to redraw areas that were obscured by Shutter's windows before taking a screenshot.") );
	$tooltips->set_tip( $hide_time_vlabel, $d->get("Configure a short timeout to give the Xserver a chance to redraw areas that were obscured by Shutter's windows before taking a screenshot.") );

	if ( defined $settings_xml->{'general'}->{'present_after'} ) {
		$present_after_active->set_active( $settings_xml->{'general'}->{'present_after'} );
	} else {
		$present_after_active->set_active(TRUE);
	}

	$tooltips->set_tip( $present_after_active, $d->get("Present main window after taking a screenshot") );

	if ( defined $settings_xml->{'general'}->{'notify_after'} ) {
		$notify_after_active->set_active( $settings_xml->{'general'}->{'notify_after'} );
	} else {
		$notify_after_active->set_active(TRUE);
	}

	$tooltips->set_tip( $notify_after_active, $d->get("Display pop-up notification after taking a screenshot") );

	if ( defined $settings_xml->{'general'}->{'notify_timeout'} ) {
		$notify_timeout_active->set_active( $settings_xml->{'general'}->{'notify_timeout'} );
	} else {
		$notify_timeout_active->set_active(TRUE);
	}

	$tooltips->set_tip( $notify_timeout_active, $d->get("Display pop-up notification when using a delay") );

	if ( defined $settings_xml->{'general'}->{'notify_ptimeout'} ) {
		$notify_ptimeout_active->set_active( $settings_xml->{'general'}->{'notify_ptimeout'} );
	} else {
		$notify_ptimeout_active->set_active(TRUE);
	}

	$tooltips->set_tip( $notify_timeout_active, $d->get("Display pop-up notification when using a delay") );

	if ( defined $settings_xml->{'general'}->{'notify_agent'} ) {
		$combobox_ns->set_active( $settings_xml->{'general'}->{'notify_agent'} );
	} else {
		$combobox_ns->set_active(TRUE);
	}

	$tooltips->set_tip( $ns_label,		$d->get("You can either choose the system-wide desktop notifications (e.g. Ubuntu's Notify-OSD) or Shutter's built-in notification system") );
	$tooltips->set_tip( $combobox_ns,	$d->get("You can either choose the system-wide desktop notifications (e.g. Ubuntu's Notify-OSD) or Shutter's built-in notification system") );

	if ( defined $settings_xml->{'general'}->{'close_at_close'} ) {
		$close_at_close_active->set_active( $settings_xml->{'general'}->{'close_at_close'} );
	} else {
		$close_at_close_active->set_active(TRUE);
	}

	$tooltips->set_tip( $close_at_close_active, $d->get("Minimize to tray when closing main window") );

	if ( defined $settings_xml->{'general'}->{'ask_on_delete'} ) {
		$ask_on_delete_active->set_active( $settings_xml->{'general'}->{'ask_on_delete'} );
	} else {
		$ask_on_delete_active->set_active(FALSE);
	}

	$tooltips->set_tip( $ask_on_delete_active, $d->get("Ask before moving files to trash") );

	if ( defined $settings_xml->{'general'}->{'delete_on_close'} ) {
		$delete_on_close_active->set_active( $settings_xml->{'general'}->{'delete_on_close'} );
	} else {
		$delete_on_close_active->set_active(FALSE);
	}

	$tooltips->set_tip( $delete_on_close_active, $d->get("Move file to trash when closing tab") );

	#end - behavior
	#--------------------------------------

	#accounts
	#--------------------------------------
	my $accounts_model = undef;
	&fct_load_accounts_tree;

	my $accounts_tree = Gtk2::TreeView->new_with_model($accounts_model);
	$tooltips->set_tip(
		$accounts_tree,
		$d->get(
			"Entering your Accounts for specific hosting-sites is optional. If entered it will give you the same benefits as the upload on the website. If you leave these fields empty you will be able to upload to the specific hosting-partner as a guest."
		)
	);

	$accounts_tree->signal_connect(
		'row-activated' => \&evt_accounts,
		'row_activated'
	);

	&fct_set_model_accounts($accounts_tree);

	#ftp uri
	my $ftp_entry_label = Gtk2::Label->new( $d->get("URI") . ":" );

	my $ftp_remote_entry = Gtk2::Entry->new;
	if ( defined $settings_xml->{'general'}->{'ftp_uri'} ) {
		$ftp_remote_entry->set_text( $settings_xml->{'general'}->{'ftp_uri'} );
	} else {
		$ftp_remote_entry->set_text("ftp://host:port/path");
	}

	$tooltips->set_tip( $ftp_entry_label, $d->get("URI\nExample: ftp://host:port/path") );

	$tooltips->set_tip( $ftp_remote_entry, $d->get("URI\nExample: ftp://host:port/path") );

	$ftp_hbox1->pack_start( $ftp_entry_label,  FALSE, TRUE, 12 );
	$ftp_hbox1->pack_start( $ftp_remote_entry, TRUE,  TRUE, 0 );

	#connection mode
	my $ftp_mode_label = Gtk2::Label->new( $d->get("Connection mode") . ":" );

	my $ftp_mode_combo = Gtk2::ComboBox->new_text;
	$ftp_mode_combo->insert_text( 0, $d->get("Active mode") );
	$ftp_mode_combo->insert_text( 1, $d->get("Passive mode") );
	if ( defined $settings_xml->{'general'}->{'ftp_mode'} ) {
		$ftp_mode_combo->set_active( $settings_xml->{'general'}->{'ftp_mode'} );
	} else {
		$ftp_mode_combo->set_active(0);
	}

	$tooltips->set_tip( $ftp_mode_label, $d->get("Connection mode") );

	$tooltips->set_tip( $ftp_mode_combo, $d->get("Connection mode") );

	$ftp_hbox2->pack_start( $ftp_mode_label, FALSE, TRUE, 12 );
	$ftp_hbox2->pack_start( $ftp_mode_combo, TRUE,  TRUE, 0 );

	#username
	my $ftp_username_label = Gtk2::Label->new( $d->get("Username") . ":" );

	my $ftp_username_entry = Gtk2::Entry->new;
	if ( defined $settings_xml->{'general'}->{'ftp_username'} ) {
		$ftp_username_entry->set_text( $settings_xml->{'general'}->{'ftp_username'} );
	} else {
		$ftp_username_entry->set_text("");
	}

	$tooltips->set_tip( $ftp_username_label, $d->get("Username") );

	$tooltips->set_tip( $ftp_username_entry, $d->get("Username") );

	$ftp_hbox3->pack_start( $ftp_username_label, FALSE, TRUE, 12 );
	$ftp_hbox3->pack_start( $ftp_username_entry, TRUE,  TRUE, 0 );

	#password
	my $ftp_password_label = Gtk2::Label->new( $d->get("Password") . ":" );

	my $ftp_password_entry = Gtk2::Entry->new;
	$ftp_password_entry->set_invisible_char("*");
	$ftp_password_entry->set_visibility(FALSE);
	if ( defined $settings_xml->{'general'}->{'ftp_password'} ) {
		$ftp_password_entry->set_text( $settings_xml->{'general'}->{'ftp_password'} );
	} else {
		$ftp_password_entry->set_text("");
	}

	$tooltips->set_tip( $ftp_password_label, $d->get("Password") );

	$tooltips->set_tip( $ftp_password_entry, $d->get("Password") );

	$ftp_hbox4->pack_start( $ftp_password_label, FALSE, TRUE, 12 );
	$ftp_hbox4->pack_start( $ftp_password_entry, TRUE,  TRUE, 0 );

	#website url
	my $ftp_wurl_label = Gtk2::Label->new( $d->get("Website URL") . ":" );

	my $ftp_wurl_entry = Gtk2::Entry->new;
	if ( defined $settings_xml->{'general'}->{'ftp_wurl'} ) {
		$ftp_wurl_entry->set_text( $settings_xml->{'general'}->{'ftp_wurl'} );
	} else {
		$ftp_wurl_entry->set_text("http://example.com/screenshots");
	}

	$tooltips->set_tip( $ftp_wurl_label, $d->get("Website URL") );

	$tooltips->set_tip( $ftp_wurl_entry, $d->get("Website URL") );

	$ftp_hbox5->pack_start( $ftp_wurl_label,  FALSE, TRUE, 12 );
	$ftp_hbox5->pack_start( $ftp_wurl_entry, TRUE,  TRUE, 0 );

	#--------------------------------------

	#packing
	#--------------------------------------

	#settings main tab
	my $label_basic = Gtk2::Label->new;
	$label_basic->set_markup( $d->get("Main") );

	$file_vbox->pack_start( $scale_box,    TRUE,  TRUE, 3 );
	$file_vbox->pack_start( $filetype_box, FALSE, TRUE, 3 );
	$file_frame->add($file_vbox);

	$save_vbox->pack_start( $save_ask_box, TRUE, TRUE, 3 );
	$save_vbox->pack_start( $save_auto_box, TRUE, TRUE, 3 );
	$save_vbox->pack_start( $filename_box, TRUE, TRUE, 3 );
	$save_vbox->pack_start( $saveDir_box, FALSE, TRUE, 3 );
	$save_vbox->pack_start( $filename_hint, TRUE, TRUE, 3 );
	$save_vbox->pack_start( $fname_autocopy_box, TRUE, TRUE, 3 );
	$save_vbox->pack_start( $image_autocopy_box, TRUE, TRUE, 3 );
	$save_vbox->pack_start( $no_autocopy_box, TRUE, TRUE, 3 );
	$save_frame->add($save_vbox);

	$capture_vbox->pack_start( $cursor_box, FALSE, TRUE, 3 );
	$capture_vbox->pack_start( $delay_box,  TRUE, TRUE, 3 );
	$capture_frame->add($capture_vbox);

	#all labels = one size
	$scale_label->set_alignment( 0, 0.5 );
	$filetype_label->set_alignment( 0, 0.5 );
	$filename_label->set_alignment( 0, 0.5 );
	$saveDir_label->set_alignment( 0, 0.5 );

	my $sg_main = Gtk2::SizeGroup->new('horizontal');
	$sg_main->add_widget($scale_label);
	$sg_main->add_widget($filetype_label);
	$sg_main->add_widget($filename_label);
	$sg_main->add_widget($saveDir_label);

	$vbox_basic->pack_start( $file_frame, FALSE, TRUE, 3 );
	$vbox_basic->pack_start( $save_frame, FALSE, TRUE, 3 );
	$vbox_basic->pack_start( $capture_frame, FALSE, TRUE, 3 );
	$vbox_basic->set_border_width(5);

	#settings actions tab
	my $label_actions = Gtk2::Label->new;
	$label_actions->set_markup( $d->get("Actions") );

	$actions_vbox->pack_start( $progname_box,  FALSE, TRUE, 3 );
	$actions_vbox->pack_start( $im_colors_box, FALSE, TRUE, 3 );
	$actions_vbox->pack_start( $thumbnail_box, FALSE, TRUE, 3 );
	$actions_vbox->pack_start( $bordereffect_box, FALSE, TRUE, 3 );
	$actions_frame->add($actions_vbox);

	#all labels = one size
	$progname_label->set_alignment( 0, 0.5 );
	$im_colors_label->set_alignment( 0, 0.5 );
	$thumbnail_label->set_alignment( 0, 0.5 );
	$bordereffect_label->set_alignment( 0, 0.5 );

	my $sg_actions = Gtk2::SizeGroup->new('horizontal');
	$sg_actions->add_widget($progname_label);
	$sg_actions->add_widget($im_colors_label);
	$sg_actions->add_widget($thumbnail_label);
	$sg_actions->add_widget($bordereffect_label);

	$vbox_actions->pack_start( $actions_frame, FALSE, TRUE, 3 );
	$vbox_actions->set_border_width(5);

	#settings advanced tab
	my $label_advanced = Gtk2::Label->new;
	$label_advanced->set_markup( $d->get("Advanced") );

	$sel_capture_vbox->pack_start( $zoom_box, FALSE, TRUE, 3 );
	$sel_capture_frame->add($sel_capture_vbox);

	#align labels (asel)
	$asel_size_label3->set_alignment( 1, 0.5 );

	my $sg_asel = Gtk2::SizeGroup->new('horizontal');
	$sg_asel->add_widget($asel_size_label1);
	$sg_asel->add_widget($asel_size_label3);

	my $sg_asel2 = Gtk2::SizeGroup->new('horizontal');
	$sg_asel2->add_widget($asel_size_label2);
	$sg_asel2->add_widget($asel_size_label4);

	$asel_capture_vbox->pack_start( $as_help_box, FALSE, TRUE, 3 );
	$asel_capture_vbox->pack_start( $asel_isize_box, FALSE, TRUE, 3 );
	$asel_capture_vbox->pack_start( $asel_isize_box2, FALSE, TRUE, 3 );
	$asel_capture_frame->add($asel_capture_vbox);

	$window_capture_vbox->pack_start( $border_box, FALSE, TRUE, 3 );
	$window_capture_vbox->pack_start( $visible_windows_box, FALSE, TRUE, 3 );
	$window_capture_frame->add($window_capture_vbox);

	$menu_capture_vbox->pack_start( $menu_delay_box, TRUE, TRUE, 3 );
	$menu_capture_vbox->pack_start( $menu_waround_box, TRUE, TRUE, 3 );
	$menu_capture_frame->add($menu_capture_vbox);

	$web_capture_vbox->pack_start( $web_width_box, FALSE, TRUE, 3 );
	$web_capture_frame->add($web_capture_vbox);

	#all labels = one size
	$menu_delay_label->set_alignment( 0, 0.5 );
	$web_width_label->set_alignment( 0, 0.5 );

	my $sg_adv = Gtk2::SizeGroup->new('horizontal');
	$sg_adv->add_widget($menu_delay_label);
	$sg_adv->add_widget($web_width_label);

	$vbox_advanced->pack_start( $sel_capture_frame, FALSE, TRUE, 3 );
	$vbox_advanced->pack_start( $asel_capture_frame, FALSE, TRUE, 3 );
	$vbox_advanced->pack_start( $window_capture_frame, FALSE, TRUE, 3 );
	$vbox_advanced->pack_start( $menu_capture_frame, FALSE, TRUE, 3 );
	$vbox_advanced->pack_start( $web_capture_frame, FALSE, TRUE, 3 );
	$vbox_advanced->set_border_width(5);

	#settings image view tab
	my $label_imageview = Gtk2::Label->new;
	$label_imageview->set_markup( $d->get("Image View") );

	$transparent_vbox->pack_start( $imageview_hbox1, TRUE, TRUE, 3 );
	$transparent_vbox->pack_start( $imageview_hbox2, TRUE, TRUE, 3 );
	$transparent_vbox->pack_start( $imageview_hbox3, TRUE, TRUE, 3 );
	$transparent_frame->add($transparent_vbox);

	$vbox_imageview->pack_start( $transparent_frame, FALSE, TRUE, 3 );
	$vbox_imageview->set_border_width(5);

	#settings behavior tab
	my $label_behavior = Gtk2::Label->new;
	$label_behavior->set_markup( $d->get("Behavior") );

	$window_vbox->pack_start( $hide_active_hbox, TRUE, TRUE, 3 );
	$window_vbox->pack_start( $pafter_active_hbox, TRUE, TRUE, 3 );
	$window_vbox->pack_start( $cac_hbox, TRUE, TRUE, 3 );
	$window_vbox->pack_start( $hide_time_hbox, TRUE, TRUE, 3 );
	$window_frame->add($window_vbox);

	$notify_vbox->pack_start( $na_active_hbox, TRUE, TRUE, 3 );
	$notify_vbox->pack_start( $nt_active_hbox, TRUE, TRUE, 3 );
	$notify_vbox->pack_start( $npt_active_hbox, TRUE, TRUE, 3 );
	$notify_vbox->pack_start( $ns_combo_hbox, TRUE, TRUE, 3 );
	$notify_frame->add($notify_vbox);

	$trash_vbox->pack_start( $aod_active_hbox, TRUE, TRUE, 3 );
	$trash_vbox->pack_start( $doc_active_hbox, TRUE, TRUE, 3 );
	$trash_frame->add($trash_vbox);

	#all labels = one size
	$hide_time_label->set_alignment( 0, 0.5 );

	my $sg_behav = Gtk2::SizeGroup->new('horizontal');
	$sg_behav->add_widget($hide_time_label);

	$vbox_behavior->pack_start( $window_frame, FALSE, TRUE, 3 );
	$vbox_behavior->pack_start( $notify_frame, FALSE, TRUE, 3 );
	$vbox_behavior->pack_start( $trash_frame, FALSE, TRUE, 3 );
	$vbox_behavior->set_border_width(5);

	#settings keyboard tab
	my $label_keyboard = Gtk2::Label->new;
	$label_keyboard->set_markup( $d->get("Keyboard") );

	#all labels = one size
	$capture_label->set_alignment( 0, 0.5 );
	$capture_sel_label->set_alignment( 0, 0.5 );

	my $sg_key = Gtk2::SizeGroup->new('horizontal');
	$sg_key->add_widget($capture_label);
	$sg_key->add_widget($capture_sel_label);

	$keybinding_vbox->pack_start( $key_box,             FALSE, TRUE, 3 );
	$keybinding_vbox->pack_start( $key_sel_box,         FALSE, TRUE, 3 );
	$keybinding_vbox->pack_start( $keybinding_mode_box, FALSE, TRUE, 3 );
	$keybinding_frame->add($keybinding_vbox);

	$vbox_keyboard->pack_start( $keybinding_frame, FALSE, TRUE, 3 );
	$vbox_keyboard->set_border_width(5);

	#settings upload tab
	my $label_accounts = Gtk2::Label->new;
	$label_accounts->set_markup( $d->get("Upload") );

	my $scrolled_accounts_window = Gtk2::ScrolledWindow->new;
	$scrolled_accounts_window->set_policy( 'automatic', 'automatic' );
	$scrolled_accounts_window->set_shadow_type('in');
	$scrolled_accounts_window->add($accounts_tree);
	$accounts_hbox->pack_start( $scrolled_accounts_window, TRUE, TRUE, 3 );
	$accounts_vbox->pack_start( $accounts_hbox,            TRUE, TRUE, 3 );
	$accounts_frame->add($accounts_vbox);

	$ftp_vbox->pack_start( $ftp_hbox1, FALSE, TRUE, 3 );
	$ftp_vbox->pack_start( $ftp_hbox2, FALSE, TRUE, 3 );
	$ftp_vbox->pack_start( $ftp_hbox3, FALSE, TRUE, 3 );
	$ftp_vbox->pack_start( $ftp_hbox4, FALSE, TRUE, 3 );
	$ftp_vbox->pack_start( $ftp_hbox5, FALSE, TRUE, 3 );
	$ftp_frame->add($ftp_vbox);

	#all labels = one size
	$ftp_entry_label->set_alignment( 0, 0.5 );
	$ftp_mode_label->set_alignment( 0, 0.5 );
	$ftp_username_label->set_alignment( 0, 0.5 );
	$ftp_password_label->set_alignment( 0, 0.5 );
	$ftp_wurl_label->set_alignment( 0, 0.5 );

	my $sg_acc = Gtk2::SizeGroup->new('horizontal');
	$sg_acc->add_widget($ftp_entry_label);
	$sg_acc->add_widget($ftp_mode_label);
	$sg_acc->add_widget($ftp_username_label);
	$sg_acc->add_widget($ftp_password_label);
	$sg_acc->add_widget($ftp_wurl_label);

	$vbox_accounts->pack_start( $accounts_frame, TRUE, TRUE, 3 );
	$vbox_accounts->pack_start( $ftp_frame,      FALSE, TRUE, 3 );
	$vbox_accounts->set_border_width(5);

	#append pages to notebook
	$notebook_settings->append_page( $vbox_basic, $label_basic );
	$notebook_settings->append_page( $vbox_advanced, $label_advanced );
	$notebook_settings->append_page( $vbox_actions, $label_actions );
	$notebook_settings->append_page( $vbox_imageview, $label_imageview );
	$notebook_settings->append_page( $vbox_behavior, $label_behavior );
	$notebook_settings->append_page( $vbox_keyboard, $label_keyboard );
	$notebook_settings->append_page( $vbox_accounts, $label_accounts );

	#plugins
	#not used in a standalone environment
	if ( keys(%plugins) > 0 && !$ENV{PAR_TEMP} ) {

		my $effects_tree = Gtk2::TreeView->new_with_model(&fct_load_plugin_tree);
		&fct_set_model_plugins($effects_tree);	
		
		my $scrolled_plugins_window = Gtk2::ScrolledWindow->new;
		$scrolled_plugins_window->set_policy( 'automatic', 'automatic' );
		$scrolled_plugins_window->set_shadow_type('in');
		$scrolled_plugins_window->add($effects_tree);
		
		my $label_plugins = Gtk2::Label->new;
		$label_plugins->set_markup( $d->get("Plugins") );
		
		my $label_treeview = Gtk2::Label->new( $d->get("The following plugins are installed") );
		$label_treeview->set_alignment( 0, 0.5 );
		$effects_vbox->pack_start( $label_treeview,          FALSE, TRUE, 1 );
		$effects_vbox->pack_start( $scrolled_plugins_window, TRUE,  TRUE, 1 );
		
		my $vbox_plugins = Gtk2::VBox->new( FALSE, 12 );
		$vbox_plugins->set_border_width(5);
		$vbox_plugins->pack_start( $effects_vbox,            TRUE,  TRUE, 1 );
		
		$notebook_settings->append_page( $vbox_plugins, $label_plugins );
	}

	#profiles
	$profiles_box->pack_start( Gtk2::Label->new( $d->get("Profile") . ":" ), FALSE, TRUE, 1 );
	$profiles_box->pack_start( $combobox_settings_profiles, TRUE,  TRUE, 6 );
	$profiles_box->pack_start( $button_profile_save,        FALSE, TRUE, 1 );
	$profiles_box->pack_start( $button_profile_delete,      FALSE, TRUE, 1 );
	$profiles_box->pack_start( $button_profile_apply,       FALSE, TRUE, 1 );

	$vbox_settings->pack_start( $profiles_box,      FALSE, TRUE, 1 );
	$vbox_settings->pack_start( $notebook_settings, TRUE,  TRUE, 1 );

	#settings
	$hbox_settings->pack_start( $vbox_settings, TRUE, TRUE, 6 );
	$settings_dialog->vbox->add($hbox_settings);
	$settings_dialog->set_default_response('apply');

	#~ #iconview
	#~ my $iconview = Gtk2::IconView->new_with_model($session_start_screen{'first_page'}->{'model'});
	#~ $iconview->set_item_width (150);
	#~ $iconview->set_pixbuf_column(0);
	#~ $iconview->set_text_column(1);
	#~ $iconview->set_selection_mode('multiple');
	#~ $iconview->signal_connect( 'selection-changed', \&evt_iconview_sel_changed );
	#~ $iconview->signal_connect( 'item-activated', \&evt_iconview_item_activated );
	#~ 
	#~ my $scrolled_window_view = Gtk2::ScrolledWindow->new;
	#~ $scrolled_window_view->set_policy( 'automatic', 'automatic' );
	#~ $scrolled_window_view->set_shadow_type('in');
	#~ $scrolled_window_view->add($iconview);
	#~ 
	#~ #add an event box to show a context menu on right-click
	#~ my $view_event = Gtk2::EventBox->new;
	#~ $view_event->add($scrolled_window_view);
	#~ $view_event->signal_connect( 'button-press-event', \&evt_iconview_button_press, $iconview );
	#~ 
	#~ 
	#~ #pack notebook and iconview into vpaned#
	#~ my $vpaned = Gtk2::VPaned->new;
	#~ $vpaned->add1($notebook);
	#~ $vpaned->add2($view_event);
	#~ 
	#~ #vpaned into vbox 
	#~ $vbox->pack_start( $vpaned, TRUE, TRUE, 0 );

	#notebook
	$vbox->pack_start( $notebook,  TRUE,  TRUE,  0 );

	#bottom toolbar
	my $nav_toolbar = $st->create_btoolbar;
	$vbox->pack_start( $nav_toolbar, FALSE, TRUE, 0 );

	#signal handler
	$st->{_back}->signal_connect( 'clicked' => sub {
			$notebook->prev_page;
		}
	);
	$st->{_forw}->signal_connect( 'clicked' => sub{
			$notebook->next_page;
		}
	);
	$st->{_home}->signal_connect( 'clicked' => sub {
			$notebook->set_current_page(0);
		}
	);

	#pack statusbar
	$status->pack_start( $cursor_status_active, FALSE, FALSE, 0 );
	$status->pack_start( Gtk2::HSeparator->new , FALSE, FALSE, 6 );

	$status->pack_start( $delay_status_label, FALSE, FALSE, 0 );
	$status->pack_start( $delay_status, FALSE, FALSE, 0 );
	$status->pack_start( Gtk2::HSeparator->new , FALSE, FALSE, 6 );

	$vbox->pack_start( $status, FALSE, FALSE, 0 );

	#--------------------------------------

	#restore session
	#--------------------------------------
	&fct_load_session;

	#open init files (cmd arguments)
	#--------------------------------------
	if(scalar @init_files > 0){
		&fct_open_files(@init_files);
	}
		
	#unblock controls
	&fct_control_signals('unblock');

	#start minimized?
	#--------------------------------------
	unless ( $sc->get_min ) {
		&fct_control_main_window ('show');
	} else {
		&fct_control_main_window ('hide');
	}

	#restore menu/toolbar settings
	#--------------------------------------
	if(defined $settings_xml->{'gui'}->{'btoolbar_active'}){
		$sm->{_menuitem_btoolbar}->set_active($settings_xml->{'gui'}->{'btoolbar_active'});
	}else{
		$sm->{_menuitem_btoolbar}->set_active(FALSE);	
	}	

	#--------------------------------------

	#FIXME
	#this is an ugly fix when 'tranparent parts' is set to background
	#we don't get the corret background color until the main window is shown
	#so we change it now
	if($trans_backg->get_active){
		&evt_value_changed (undef, 'transp_toggled');
	}

	#update the first tab on startup
	&fct_update_info_and_tray();

	#load saved settings
	#--------------------------------------
	my $folder_to_save = $settings_xml->{'general'}->{'folder'} || $ENV{'HOME'};
	if ( $sc->get_start_with && $folder_to_save ) {
		if ( $sc->get_start_with eq "raw" ) {
			&evt_take_screenshot( 'global_keybinding', "raw", $folder_to_save );
		} elsif ( $sc->get_start_with eq "select" ) {
			&evt_take_screenshot( 'global_keybinding', "select", $folder_to_save );
		} elsif ( $sc->get_start_with eq "window" ) {
			&evt_take_screenshot( 'global_keybinding', "window", $folder_to_save );
		} elsif ( $sc->get_start_with eq "section" ) {
			&evt_take_screenshot( 'global_keybinding', "section", $folder_to_save );
		}
	}

	Gtk2->main;



	0;

	#events
	#--------------------------------------
	sub evt_value_changed {
		my ( $widget, $data ) = @_;
		print "\n$data was emitted by widget $widget\n"
			if $sc->get_debug;

		return FALSE unless $data;

		#checkbox for "open with" -> entry active/inactive
		if ( $data eq "progname_toggled" ) {
			if ( $progname_active->get_active ) {
				$progname->set_sensitive(TRUE);
			} else {
				$progname->set_sensitive(FALSE);
			}
		}

		#checkbox for "color depth" -> entry active/inactive
		if ( $data eq "im_colors_toggled" ) {
			if ( $im_colors_active->get_active ) {
				$combobox_im_colors->set_sensitive(TRUE);
			} else {
				$combobox_im_colors->set_sensitive(FALSE);
			}
		}

		#radiobuttons for "transparent parts"
		if ( $data eq "transp_toggled" ) {

			#Sets how the view should draw transparent parts of images with an alpha channel		
			my $color = $trans_custom_btn->get_color;
			my $color_string = sprintf( "%02x%02x%02x", $color->red / 257, $color->green / 257, $color->blue / 257 );
			
			my $mode;
			if ( $trans_check->get_active ) {
				$mode = 'grid';	
			}elsif ( $trans_custom->get_active ) {
				$mode = 'color';
			}elsif ( $trans_backg->get_active ) {		
				$mode = 'color';
				my $bg = $window->get_style->bg('normal');
				$color_string = sprintf( "%02x%02x%02x", $bg->red / 257, $bg->green / 257, $bg->blue / 257 );			
			}

			#change all imageviews in session
			foreach my $key (keys %session_screens){
				if($session_screens{$key}->{'image'}){
					$session_screens{$key}->{'image'}->set_transp($mode, hex $color_string);
				}
			}
							
		}

		#"save" toggled
		if ( $data eq "save_toggled" ) {
			$filename_label->set_sensitive($save_auto_active->get_active); 
			$filename->set_sensitive($save_auto_active->get_active); 
			$saveDir_label->set_sensitive($save_auto_active->get_active); 
			$saveDir_label->set_sensitive($save_auto_active->get_active); 
			$saveDir_button->set_sensitive($save_auto_active->get_active); 
		}

		#"cursor_status" toggled
		if ( $data eq "cursor_status_toggled" ) {
			$cursor_active->set_active($cursor_status_active->get_active); 
		}

		#"cursor" toggled
		if ( $data eq "cursor_toggled" ) {
			$cursor_status_active->set_active($cursor_active->get_active);
		}

		#value for "delay" -> update text
		if ( $data eq "delay_changed" ) {
			$delay_status->set_value($delay->get_value); 
			$delay_vlabel->set_text($d->nget("second", "seconds", $delay->get_value) );
		}

		#value for "delay" -> update text
		if ( $data eq "delay_status_changed" ) {
			$delay->set_value($delay_status->get_value); 
			$delay_status_vlabel->set_text($d->nget("second", "seconds", $delay_status->get_value) );
		}
		
		#value for "menu_delay" -> update text
		if ( $data eq "menu_delay_changed" ) {
			$menu_delay_vlabel->set_text( $d->nget("second", "seconds", $menu_delay->get_value) ); 
		}
		
		#value for "hide_time" -> update text
		if ( $data eq "hide_time_changed" ) {
			$hide_time_vlabel->set_text( $d->nget("millisecond", "milliseconds", $hide_time->get_value) ); 
		}

		#checkbox for "thumbnail" -> HScale active/inactive
		if ( $data eq "thumbnail_toggled" ) {
			if ( $thumbnail_active->get_active ) {
				$thumbnail->set_sensitive(TRUE);
			} else {
				$thumbnail->set_sensitive(FALSE);
			}
		}

		#quality value changed
		if ( $data eq "qvalue_changed" ) {
			my $settings = undef;
			if(defined $sc->get_globalsettings_object){
				$settings = $sc->get_globalsettings_object;
			}else{
				$settings = Shutter::App::GlobalSettings->new();
				$sc->set_globalsettings_object($settings);
			}
			if ( $combobox_type->get_active_text =~ /jpeg/ ) {
				$settings->set_jpg_quality($scale->get_value);
			} elsif ( $combobox_type->get_active_text =~ /png/ ) {
				$settings->set_png_quality($scale->get_value);
			} else {
				$settings->clear_quality_settings();
			}
		}	
			
		#checkbox for "bordereffect" -> HScale active/inactive
		if ( $data eq "bordereffect_toggled" ) {
			if ( $bordereffect_active->get_active ) {
				$bordereffect->set_sensitive(TRUE);
			} else {
				$bordereffect->set_sensitive(FALSE);
			}
		}

		#value for "bordereffect" -> update text
		if ( $data eq "bordereffect_changed" ) {
			$bordereffect_vlabel->set_text( $d->nget("pixel", "pixels", $bordereffect->get_value) ); 
		}

		#filetype changed
		if ( $data eq "type_changed" ) {
			if ( $combobox_type->get_active_text =~ /jpeg/ ) {
				$scale->set_sensitive(TRUE);
				$scale_label->set_sensitive(TRUE);
				$scale->set_range( 1, 100 );
				$scale->set_value(90);
				$scale_label->set_text( $d->get("Quality") . ":" );
			} elsif ( $combobox_type->get_active_text =~ /png/ ) {
				$scale->set_sensitive(TRUE);
				$scale_label->set_sensitive(TRUE);
				$scale->set_range( 0, 9 );
				$scale->set_value(9);
				$scale_label->set_text( $d->get("Compression") . ":" );
			} else {
				$scale->set_sensitive(FALSE);
				$scale_label->set_sensitive(FALSE);
			}
		}

		#notify agent changed
		if ( $data eq "ns_changed" ) {
			if ( $combobox_ns->get_active == 0 ) {
				$sc->set_notification_object(Shutter::App::Notification->new);		
			} else {
				$sc->set_notification_object(Shutter::App::ShutterNotification->new($sc));			
			}
		}	

		return TRUE;
	}

	sub evt_take_screenshot {
		my ( $widget, $data, $folder_from_config ) = @_;

		#get xid if any window was selected from the submenu...
		my $selfcapture = FALSE;
		if ( $data =~ /^shutter_window_direct(.*)/ ) {
			my $xid = $1;
			$selfcapture = TRUE if $xid == $window->window->XID;
		}

		#hide mainwindow
		if ( $hide_active->get_active && $data ne "web" && $data ne "tray_web"
			&& !$is_hidden
			&& !$selfcapture ) {
				
			&fct_control_main_window('hide');
			
		}else{

			#save current position of main window
			( $window->{x}, $window->{y} ) = $window->get_position;
			
		}

		#close last message displayed
		my $notify 	= $sc->get_notification_object;
		$notify->close;

		#disable signal-handler
		&fct_control_signals('block');

		if ( $data eq "web" || $data eq "tray_web" ){
			&fct_take_screenshot($widget, $data, $folder_from_config);
			#unblock signal handler
			&fct_control_signals('unblock');
		}elsif ( $data eq "menu" || 
				 $data eq "tray_menu" ||
				 $data eq "tooltip" ||
				 $data eq "tray_tooltip" ){
					 
			my $scd_text;
			if ( $data eq "menu" || $data eq "tray_menu" ) {
				$scd_text = $d->get("Please activate the menu you want to capture");
			}elsif( $data eq "tooltip" || $data eq "tray_tooltip" ) {
				$scd_text = $d->get("Please activate the tooltip you want to capture");
			}	 
				 
			#show notification messages displaying the countdown
			if($notify_ptimeout_active->get_active){
				my $notify 	= $sc->get_notification_object;
				my $ttw 	= $menu_delay->get_value;
		
				#first notification immediately
				$notify->show( sprintf($d->nget("Screenshot will be taken in %s second", "Screenshot will be taken in %s seconds", $ttw) , $ttw), 
							   $scd_text
							 );
				$ttw--;
				
				#delay is only 1 second
				#do not show any further messages
				if($ttw >= 1){
					#then controlled via timeout
					Glib::Timeout->add (1000, sub{
						$notify->show( sprintf($d->nget("Screenshot will be taken in %s second", "Screenshot will be taken in %s seconds", $ttw) , $ttw), 
									   $scd_text 
									 );
						$ttw--;
						if($ttw == 0){			
							
							#close last message with a short delay (less than a second)
							Glib::Timeout->add (500, sub{
								$notify->close;
								return FALSE;	
							});	
							
							return FALSE;
							
						}else{
							
							return TRUE;	
						
						}	
					});
				}else{
					#close last message with a short delay (less than a second)
					Glib::Timeout->add (500, sub{
						$notify->close;
						return FALSE;	
					});				
				}
			}#notify not activated	
			
			#A short timeout to give the server a chance to
			#redraw the area that was obscured by our dialog.
			Glib::Timeout->add ($menu_delay->get_value * 1000, sub{
				&fct_take_screenshot($widget, $data, $folder_from_config);
				#unblock signal handler
				&fct_control_signals('unblock');
				return FALSE;	
			});
		}else{
			#A short timeout to give the server a chance to
			#redraw the area that was obscured by our dialog.
			if($hide_active->get_active){
				Glib::Timeout->add ($hide_time->get_value, sub{
					&fct_take_screenshot($widget, $data, $folder_from_config);
					#unblock signal handler
					&fct_control_signals('unblock');
					return FALSE;	
				});
			}else{
				&fct_take_screenshot($widget, $data, $folder_from_config);
				#unblock signal handler
				&fct_control_signals('unblock');			
			}			
		}		
		
		
		return TRUE;
	}

	sub evt_behavior_handle {
		my ( $widget, $data ) = @_;
		print "\n$data was emitted by widget $widget\n"
			if $sc->get_debug;

		#checkbox for "keybinding" -> entry active/inactive
		if ( $data eq "keybinding_toggled" ) {
			if ( $keybinding_active->get_active ) {
				$capture_key->set_sensitive(TRUE);
			} else {
				$capture_key->set_sensitive(FALSE);
			}	
		}

		#checkbox for "keybinding_sel" -> entry active/inactive
		if ( $data eq "keybinding_sel_toggled" ) {
			if ( $keybinding_sel_active->get_active ) {
				$capture_sel_key->set_sensitive(TRUE);
				$combobox_keybinding_mode->set_sensitive(TRUE);
			} else {
				$capture_sel_key->set_sensitive(FALSE);
				$combobox_keybinding_mode->set_sensitive(FALSE);
			}
		}
			
		return TRUE;
	}

	sub evt_notebook_switch {
		my ( $widget, $pointer, $int ) = @_;

		my $key = &fct_get_file_by_index($int);
		if($key){

			foreach (keys %session_screens){
				#set pixbuf for current item
				if ($_ eq $key){
					if($session_screens{$key}->{'long'}){
						
						&fct_update_info_and_tray($key);
																							
						#do nothing if
						#the view does already show a pixbuf
						unless($session_screens{$_}->{'image'}->get_pixbuf){
							eval{
								#~ print "setting ", $_, "\n";
								$session_screens{$_}->{'image'}->set_pixbuf(Gtk2::Gdk::Pixbuf->new_from_file( $session_screens{$key}->{'long'} ));								
							}
						}
						
					}
					next;
				}
				#unset imageview for all other items
				if(defined $session_screens{$_}->{'image'} && $session_screens{$_}->{'image'}->get_pixbuf){
					eval{
						#~ print "unsetting ", $_, "\n";
						$session_screens{$_}->{'image'}->set_pixbuf(undef);
					};
					if($@){
						delete $session_screens{$_};
						next;	
					}
				}
			}

		}else{
			&fct_update_info_and_tray("session");		
		}

		#unselect all items in session tab
		#when we move away
		if($int == 0){
			$session_start_screen{'first_page'}->{'view'}->unselect_all;
		}
		
		#enable/disable menu entry when we switch tabs	
		&fct_update_actions($int, $key);
		
		return TRUE;
	}

	sub evt_delete_window {
		my ( $widget, $data ) = @_;
		print "\n$data was emitted by widget $widget\n"
			if $sc->get_debug;

		if ( $data ne "quit" && $close_at_close_active->get_active ) {
			$window->hide;
			$is_hidden = TRUE;
			return TRUE;
		}

		#hide window and save settings
		$window->hide;
		&fct_save_settings(undef);
		&fct_save_settings( $combobox_settings_profiles->get_active_text ) 
			if $combobox_settings_profiles->get_active != -1;

		Gtk2->main_quit;
		return FALSE;
	}

	sub evt_bug {
		$shf->xdg_open( undef, "https://bugs.launchpad.net/shutter", undef );
	}

	sub evt_question {
		$shf->xdg_open( undef, "https://answers.launchpad.net/shutter", undef );
	}

	sub evt_translate {
		$shf->xdg_open( undef, "https://translations.launchpad.net/shutter", undef );
	}

	sub evt_about {
		Shutter::App::AboutDialog->new($sc)->show;
	}

	sub evt_show_systray {
		my ( $widget, $data ) = @_;
		if ( $sc->get_debug ) {
			print "\n$data was emitted by widget $widget\n";
		}

		#left button (mouse)
		if ( $_[1]->button == 1 ) {
			if ( $window->visible ) {
				&fct_control_main_window ('hide');
			} else {
				&fct_control_main_window ('show');
			}
		}

		#right button (mouse)
		elsif ( $_[1]->button == 3 ) {
			$tray_menu->popup(
				undef,    # parent menu shell
				undef,    # parent menu item
				undef,    # menu pos func
				undef,    # data
				$data->button,
				$data->time
			);	
		}
		return TRUE;
	}

	sub evt_show_systray_statusicon {
		my ( $widget, $button, $time, $tray ) = @_;
		if ( $sc->get_debug ) {
			print "\n$button, $time was emitted by widget $widget\n";
		}

		$tray_menu->popup(
			undef,    # parent menu shell
			undef,    # parent menu item
			sub {
				return Gtk2::StatusIcon::position_menu( $tray_menu, 0, 0, $tray );
			},        # menu pos func
			undef,    # data
			$time ? $button : 0,
			$time
		);
		
		return TRUE;
	}

	sub evt_activate_systray_statusicon {
		my ( $widget, $data, $tray ) = @_;
		if ( $sc->get_debug ) {
			print "\n$data was emitted by widget $widget\n";
		}

		unless ( $is_hidden ) {
			&fct_control_main_window ('hide');
		} else {
			&fct_control_main_window ('show');
		}
		return TRUE;
	}

	sub evt_accounts {
		my ( $tree, $path, $column ) = @_;

		#open browser if register url is clicked
		if ( $column->get_title eq $d->get("Register") ) {
			my $model         = $tree->get_model();
			my $account_iter  = $model->get_iter($path);
			my $account_value = $model->get_value( $account_iter, 3 );
			$shf->xdg_open( undef, $account_value, undef );
		}
		return TRUE;
	}

	sub evt_tab_button_press {
		my ($ev_box, $ev, $key) = @_;
		
		#right click
		if($key && $ev->button == 3 && $ev->type eq 'button-press'){
			$sm->{_menu_large_actions}->popup(
				undef,    # parent menu shell
				undef,    # parent menu item
				undef,    # menu pos func
				undef,    # data
				$ev->button,
				$ev->time
			);		
		}
		
		return TRUE;
	}

	sub evt_iconview_button_press {
		my $ev_box	= shift;
		my $ev 		= shift;
		my $view 	= shift;
		
		my $path = $view->get_path_at_pos ($ev->x, $ev->y);
		
		if($path){
			#select item
			$view->select_path ($path);		

			$sm->{_menu_large_actions}->popup(
				undef,    # parent menu shell
				undef,    # parent menu item
				undef,    # menu pos func
				undef,    # data
				$ev->button,
				$ev->time
			);
			
		}
		
		return TRUE;
	}

	sub evt_iconview_sel_changed {
		my ( $view, $data ) = @_;

		#we don't handle selection changes 
		#if we are not in the session tab
		if (&fct_get_current_file){
		
			return FALSE; 		
		}

		my @sel_items = $view->get_selected_items;	
		
		#enable/disable menu entry when we are in the session tab and selection changes
		if(scalar @sel_items == 1){
			my $key = undef;
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						$key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
					}
				},
				undef
			);		
			&fct_update_actions( scalar @sel_items, $key );
		}else{
			&fct_update_actions( scalar @sel_items );
		}
			
		return TRUE;
	}

	sub fct_get_last_capture{
		#~ #determine last capture and return the relevant key
		#~ my $last_capture_tstamp = 0;
		#~ my $last_capture_key 	= 0;
		#~ foreach my $key (keys %session_screens){
			#~ if(exists $session_screens{$key}->{'history'} && defined $session_screens{$key}->{'history'}){
				#~ if(exists $session_screens{$key}->{'history_timestamp'} && defined $session_screens{$key}->{'history_timestamp'}){
					#~ if($session_screens{$key}->{'history_timestamp'} > $last_capture_tstamp){
						#~ $last_capture_tstamp = $session_screens{$key}->{'history_timestamp'}; 
						#~ $last_capture_key = $key;
					#~ }
				#~ }
			#~ }
		#~ }
		#~ return $last_capture_key;
		if(exists $session_start_screen{'first_page'}->{'history'} && defined $session_start_screen{'first_page'}->{'history'}){
			return $session_start_screen{'first_page'}->{'history'};
		}
		return FALSE;
	}

	sub fct_ret_upload_links_menu {
	   my $key = shift;
		
	   my $traytheme = $sc->get_theme;
	   
	   my $menu_links = Gtk2::Menu->new;
	   
	   my $nmenu_entries = 0;
		
		if(defined $key && exists $session_screens{$key}->{'links'}){
			foreach my $link (keys %{$session_screens{$key}->{'links'}}){
			#~ print Dumper $session_screens{$key}->{'links'}->{$link}, "\n";

			#no longer valid
			next unless exists $session_screens{$key}->{'links'}->{$link}->{'puburl'};
			next unless defined $session_screens{$key}->{'links'}->{$link}->{'puburl'};

			 #create menu entry
			 my $menuitem_link = Gtk2::ImageMenuItem->new_with_mnemonic( $session_screens{$key}->{'links'}->{$link}->{'menuentry'} );
			 if(defined $session_screens{$key}->{'links'}->{$link}->{'menuimage'}){
				if($traytheme->has_icon($session_screens{$key}->{'links'}->{$link}->{'menuimage'})){
				   $menuitem_link->set_image( Gtk2::Image->new_from_icon_name( $session_screens{$key}->{'links'}->{$link}->{'menuimage'}, 'menu' ) );	
				}
			 }
			 $menuitem_link->signal_connect(
				activate => sub {
				   $clipboard->set_text($session_screens{$key}->{'links'}->{$link}->{'puburl'});
				}
			 );

			 $menu_links->append($menuitem_link);
			 
			 $nmenu_entries++;
			 
			}
		}
	   
		$menu_links->show_all;

		return ($nmenu_entries,$menu_links);
	}

	sub fct_update_actions {
		my $n_items = shift;
		my $key 	= shift;

		Glib::Idle->add(sub{

			#does the file still exist?
			if(defined $key){
				return FALSE unless exists $session_screens{$key};
			}
			
			#TRAY
			#--------------------------------------
			
			#last capture
			foreach($tray_menu->get_children){
				if ($_->get_name eq 'redoshot'){
					$_->set_sensitive(&fct_get_last_capture);
					last;
				}	
			}

			#TOOLBAR
			#--------------------------------------
		
			#last capture
			$st->{_redoshot}->set_sensitive(&fct_get_last_capture);
			
			#goocanvas is optional, don't enable it when not installed
			if($goocanvas) {
				$st->{_edit}->set_sensitive($n_items);
			}else{
				$st->{_edit}->set_sensitive(FALSE);
			}
			
			$st->{_upload}->set_sensitive($n_items);
		
			#MENU
			#--------------------------------------
			
			#last capture
			$sm->{_menuitem_redoshot}->set_sensitive($st->{_redoshot}->is_sensitive);
			
			#file
			$sm->{_menuitem_save_as}->set_sensitive($n_items);
			#~ $sm->{_menuitem_export_svg}->set_sensitive($n_items);
			$sm->{_menuitem_export_pdf}->set_sensitive($n_items);
			$sm->{_menuitem_pagesetup}->set_sensitive($n_items);
			$sm->{_menuitem_print}->set_sensitive($n_items);
			$sm->{_menuitem_email}->set_sensitive($n_items);
			$sm->{_menuitem_close}->set_sensitive($n_items);		
			$sm->{_menuitem_close_all}->set_sensitive($n_items);		
		
			#edit
			if($n_items && defined $key && defined @{$session_screens{$key}->{'undo'}} && scalar @{$session_screens{$key}->{'undo'}} > 1){
				$sm->{_menuitem_undo}->set_sensitive(TRUE);			
			}else{
				$sm->{_menuitem_undo}->set_sensitive(FALSE);
			}
		
			if($n_items && defined $key && defined @{$session_screens{$key}->{'redo'}} && scalar @{$session_screens{$key}->{'redo'}} > 0){
				$sm->{_menuitem_redo}->set_sensitive(TRUE);			
			}else{
				$sm->{_menuitem_redo}->set_sensitive(FALSE);
			}
				
			$sm->{_menuitem_trash}->set_sensitive($n_items);
			$sm->{_menuitem_copy}->set_sensitive($n_items);
			$sm->{_menuitem_copy_filename}->set_sensitive($n_items);	
		
			#view
			$sm->{_menuitem_zoom_in}->set_sensitive($n_items);
			$sm->{_menuitem_zoom_out}->set_sensitive($n_items);
			$sm->{_menuitem_zoom_100}->set_sensitive($n_items);
			$sm->{_menuitem_zoom_best}->set_sensitive($n_items);
		
			#screenshot
			$sm->{_menuitem_reopen_default}->visible($n_items);
			$sm->{_menuitem_reopen_default}->set_sensitive($n_items);
			$sm->{_menuitem_reopen}->set_sensitive($n_items);
			$sm->{_menuitem_rename}->set_sensitive($n_items);
			
			#upload links
			#~ $sm->{_menuitem_links}->set_sensitive(&fct_get_upload_links($key));
			#upload links
			my ($nmenu_entries, $menu_links) = &fct_ret_upload_links_menu($key);
			if($nmenu_entries){
				$sm->{_menuitem_links}->set_submenu($menu_links);
			}else{
				$sm->{_menuitem_links}->set_submenu(undef);
			}
			$sm->{_menuitem_links}->set_sensitive($nmenu_entries);		
		
			#nautilus-sendto is optional, don't enable it when not installed
			if ( $nautilus_sendto ) {
				$sm->{_menuitem_send}->set_sensitive($n_items);	
			}else{
				$sm->{_menuitem_send}->set_sensitive(FALSE);
			}	
		
			$sm->{_menuitem_upload}->set_sensitive($n_items);
				
			#goocanvas is optional, don't enable it when not installed
			if ($goocanvas) {
				$sm->{_menuitem_draw}->set_sensitive($n_items);
			}else{
				$sm->{_menuitem_draw}->set_sensitive(FALSE);
			}		
		
			$sm->{_menuitem_plugin}->set_sensitive($n_items);
		
			#redoshot_this
			if(defined $key && exists $session_screens{$key}->{'history'} && defined $session_screens{$key}->{'history'}){
				$sm->{_menuitem_redoshot_this}->set_sensitive($n_items);
			}else{
				$sm->{_menuitem_redoshot_this}->set_sensitive(FALSE);
			}
			
			#right-click menu
			$sm->{_menuitem_large_reopen_default}->visible($n_items);
			$sm->{_menuitem_large_reopen_default}->set_sensitive($n_items);
			$sm->{_menuitem_large_reopen}->set_sensitive($n_items);
			$sm->{_menuitem_large_rename}->set_sensitive($n_items);
			$sm->{_menuitem_large_trash}->set_sensitive($n_items);
			$sm->{_menuitem_large_copy}->set_sensitive($n_items);
			$sm->{_menuitem_large_copy_filename}->set_sensitive($n_items);

			#upload links
			my ($nmenu_entries_large, $menu_links_large) = &fct_ret_upload_links_menu($key);
			if($nmenu_entries_large){
				$sm->{_menuitem_large_links}->set_submenu($menu_links_large);
			}else{
				$sm->{_menuitem_large_links}->set_submenu(undef);
			}
			$sm->{_menuitem_large_links}->set_sensitive($nmenu_entries_large);

			#nautilus-sendto is optional, don't enable it when not installed
			if ( $nautilus_sendto ) {
				$sm->{_menuitem_large_send}->set_sensitive($n_items);	
			}else{
				$sm->{_menuitem_large_send}->set_sensitive(FALSE);
			}	
		
			$sm->{_menuitem_large_upload}->set_sensitive($n_items);
				
			#goocanvas is optional, don't enable it when not installed
			if ($goocanvas) {
				$sm->{_menuitem_large_draw}->set_sensitive($n_items);
			}else{
				$sm->{_menuitem_large_draw}->set_sensitive(FALSE);
			}		
		
			$sm->{_menuitem_large_plugin}->set_sensitive($n_items);
		
			#redoshot_this
			if(defined $key && exists $session_screens{$key}->{'history'} && defined $session_screens{$key}->{'history'}){
				$sm->{_menuitem_large_redoshot_this}->set_sensitive($n_items);
			}else{
				$sm->{_menuitem_large_redoshot_this}->set_sensitive(FALSE);
			}
		
			return FALSE;
		});
			
		return TRUE;
	}

	sub evt_iconview_item_activated {
		my ( $view, $path, $data ) = @_;
		
		my $model = $view->get_model;
		
		my $iter = $model->get_iter($path);
		my $key = $model->get_value( $iter, 2 );

		$notebook->set_current_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );

		return TRUE;
	}

	sub evt_show_settings {
		&fct_check_installed_programs;

		$settings_dialog->show_all;
		my $settings_dialog_response = $settings_dialog->run;
		
		&fct_post_settings($settings_dialog);	
		
		if ( $settings_dialog_response eq "close" ) {
			return TRUE;
		} else {
			return FALSE;
		}
	}

	sub fct_post_settings {
		my $settings_dialog = shift;

		#unset profile combobox when profile was not applied
		if ( $current_profile_indx != $combobox_settings_profiles->get_active ) {
			$combobox_settings_profiles->set_active($current_profile_indx);
		}

		$settings_dialog->hide();
		
		#save directly
		&fct_save_settings(undef);
		&fct_save_settings( $combobox_settings_profiles->get_active_text ) 
			if $combobox_settings_profiles->get_active != -1;
		
		#we need to update the first tab here
		#because the profile might have changed
		&fct_update_info_and_tray();

		return TRUE;
	}

	sub evt_open {
		my ( $widget, $data ) = @_;
		print "\n$data was emitted by widget $widget\n"
			if $sc->get_debug;

		#do we need to open a filechooserdialog?
		#maybe we open a recently opened file that is 
		#selected via menu
		my @new_files;	
		unless($widget =~ /Gtk2::RecentChooserMenu/){
			my $fs = Gtk2::FileChooserDialog->new(
				$d->get("Choose file to open"), $window,
				'open',
				'gtk-cancel' => 'reject',
				'gtk-open'   => 'accept'
			);
			$fs->set_select_multiple(TRUE);

			#preview widget
			my $iprev = Gtk2::Image->new;
			$fs->set_preview_widget($iprev);
		
			$fs->signal_connect(
				'selection-changed' => sub {
					if(my $pfilename = $fs->get_preview_filename){
						my $pixbuf = undef;
						eval{
							$pixbuf = Gtk2::Gdk::Pixbuf->new_from_file_at_scale ($pfilename, 200, 200, TRUE);
						};
						if($@){
							$fs->set_preview_widget_active(FALSE);
						}else{
							$fs->get_preview_widget->set_from_pixbuf($pixbuf);
							$fs->set_preview_widget_active(TRUE)
						}
					}else{
						$fs->set_preview_widget_active(FALSE);
					}
				}
			);

			my $filter_all = Gtk2::FileFilter->new;
			$filter_all->set_name( $d->get("All compatible image formats") );
			$fs->add_filter($filter_all);
			
			foreach ( Gtk2::Gdk::Pixbuf->get_formats ) {
				my $filter = Gtk2::FileFilter->new;
				
				#add all known formats to the dialog			
				$filter->set_name( $_->{name} . " - " . $_->{description} );
				
				foreach ( @{ $_->{extensions} } ) {
					$filter->add_pattern( "*." . uc $_ );
					$filter_all->add_pattern( "*." . uc $_ );
					$filter->add_pattern( "*." . $_ );
					$filter_all->add_pattern( "*." . $_ );
				}
				$fs->add_filter($filter);
			}
			
			#set default filter
			$fs->set_filter($filter_all);
			
			#get current file
			my $key = &fct_get_current_file;
			
			#go to recently used folder
			if(defined $sc->get_ruof && $shf->folder_exists($sc->get_ruof)){
				$fs->set_current_folder( $sc->get_ruof );
			}else{
				if ($key) {
					$fs->set_filename( $session_screens{$key}->{'long'} );
				} elsif ( $saveDir_button->get_current_folder ) {
					$fs->set_current_folder( $saveDir_button->get_current_folder );
				}else{
					$fs->set_current_folder( $ENV{'HOME'} );
				}
			}
			
			my $fs_resp = $fs->run;

			if ( $fs_resp eq "accept" ) {
				@new_files = $fs->get_filenames;
				
				#keep folder in mind
				if($new_files[0]){
					my ( $oshort, $ofolder, $oext ) = fileparse( $new_files[0], qr/\.[^.]*/ );
					$sc->set_ruof($ofolder) if defined $ofolder;
				}
				
				$fs->destroy();
			} else {
				$fs->destroy();
			}

		}else{
			push @new_files, $widget->get_current_uri;
		}

		#call function to open files - with progress bar etc.
		&fct_open_files(@new_files);

		return TRUE;
	}

	sub evt_page_setup {
		my ( $widget, $data ) = @_;

		#restore settings if prossible
		my $ssettings = Gtk2::PrintSettings->new;
		if ( $shf->file_exists("$ENV{ HOME }/.shutter/printing.xml") ) {
			eval { $ssettings = Gtk2::PrintSettings->new_from_file("$ENV{ HOME }/.shutter/printing.xml"); };
		}

		$pagesetup = Gtk2::Print->run_page_setup_dialog( $window, $pagesetup, $ssettings );

		return TRUE;
	}

	sub evt_save_as {
		my ( $widget, $data ) = @_;
		print "\n$data was emitted by widget $widget\n"
			if $sc->get_debug;

		my $key = &fct_get_current_file;

		my @save_as_files;
		#single file
		if ($key) {

			push @save_as_files, $key;

		#session tab
		} else {

			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						push @save_as_files, $key;
					}
				},
				undef
			);

		}
		
		#determine requested filetype
		my $rfiletype = undef;
		if($data eq 'menu_export_svg'){
			$rfiletype = 'svg';
		}elsif($data eq 'menu_export_pdf'){
			$rfiletype = 'pdf';
		}
		
		foreach (@save_as_files){
			&dlg_save_as($_, $rfiletype);
		}

		return TRUE;
		
	}

	sub evt_save_profile {
		my ( $widget, $combobox_settings_profiles, $current_profiles_ref ) = @_;
		my $curr_profile_name = $combobox_settings_profiles->get_active_text
			|| "";
		my $new_profile_name = &dlg_profile_name( $curr_profile_name, $combobox_settings_profiles );

		if ($new_profile_name) {
			if ( $curr_profile_name ne $new_profile_name ) {
				$combobox_settings_profiles->prepend_text($new_profile_name);
				$combobox_settings_profiles->set_active(0);
				$current_profile_indx = 0;

				#unshift to array as well
				unshift( @{$current_profiles_ref}, $new_profile_name );
			
				&fct_update_profile_selectors($combobox_settings_profiles, $current_profiles_ref);

			}
			&fct_save_settings($new_profile_name);
		}
		return TRUE;
	}

	sub evt_delete_profile {
		my ( $widget, $combobox_settings_profiles, $current_profiles_ref ) = @_;
		if ( $combobox_settings_profiles->get_active_text ) {
			my $active_text  = $combobox_settings_profiles->get_active_text;
			my $active_index = $combobox_settings_profiles->get_active;
			unlink( "$ENV{'HOME'}/.shutter/profiles/" . $active_text . ".xml" );
			unlink( "$ENV{'HOME'}/.shutter/profiles/" . $active_text . "_accounts.xml" );

			unless ( $shf->file_exists( "$ENV{'HOME'}/.shutter/profiles/" . $active_text . ".xml" )
				|| $shf->file_exists( "$ENV{'HOME'}/.shutter/profiles/" . $active_text . "_accounts.xml" ) )
			{
				$combobox_settings_profiles->remove_text($active_index);
				$combobox_settings_profiles->set_active( $combobox_settings_profiles->get_active + 1 );
				$current_profile_indx = $combobox_settings_profiles->get_active;

				#remove from array as well
				splice( @{$current_profiles_ref}, $active_index, 1 );

				&fct_update_profile_selectors($combobox_settings_profiles, $current_profiles_ref);
				
				&fct_show_status_message( 1, $d->get("Profile deleted") );
			} else {
				$sd->dlg_error_message( $d->get("Profile could not be deleted"), $d->get("Failed") );
				&fct_show_status_message( 1, $d->get("Profile could not be deleted") );
			}
		}
		return TRUE;
	}

	sub evt_apply_profile {
		my ( $widget, $combobox_settings_profiles, $current_profiles_ref ) = @_;

		if ( $combobox_settings_profiles->get_active_text ) {
			$settings_xml = &fct_load_settings( 'profile_load', $combobox_settings_profiles->get_active_text );
			$current_profile_indx = $combobox_settings_profiles->get_active;
			my $current_profile_text = $combobox_settings_profiles->get_active_text;
					
			&fct_update_profile_selectors($combobox_settings_profiles, $current_profiles_ref, $widget);	

			&fct_update_info_and_tray();

			&fct_show_status_message( 1, sprintf( $d->get("Profile %s loaded successfully"), "'" . $current_profile_text . "'") );
		}
		
		return TRUE;
	}

	#--------------------------------------

	#functions
	#--------------------------------------

	sub fct_create_session_notebook {
		
		$notebook->set( 'homogeneous' => TRUE );
		$notebook->set( 'scrollable' => TRUE );

		#enable dnd for it
		$notebook->drag_dest_set('all', ['copy','private','default','move','link','ask']);
		$notebook->signal_connect(drag_data_received => \&fct_drop_handler);
		
		my $target_list = Gtk2::TargetList->new();
		my $atom_dest = Gtk2::Gdk::Atom->new('text/uri-list');
		$target_list->add($atom_dest, 0, 0);
		$notebook->drag_dest_set_target_list($target_list);
		
		#packing and first page
		my $hbox_first_label = Gtk2::HBox->new( FALSE, 0 );
		my $thumb_first_icon = Gtk2::Image->new_from_stock( 'gtk-index', 'menu' );
		my $tab_first_label = Gtk2::Label->new();
		$tab_first_label->set_markup( "<b>" . $d->get("Session") . "</b>" );
		$hbox_first_label->pack_start( $thumb_first_icon, FALSE, FALSE, 1 );
		$hbox_first_label->pack_start( $tab_first_label,  FALSE, FALSE, 1 );
		$hbox_first_label->show_all;

		my $new_index = $notebook->append_page( fct_create_tab( "", TRUE ), $hbox_first_label );
		$session_start_screen{'first_page'}->{'tab_child'} = $notebook->get_nth_page($new_index);

		$notebook->signal_connect( 'switch-page' => \&evt_notebook_switch );

		return $notebook;
	}

	sub fct_integrate_screenshot_in_notebook {
		my ($uri, $pixbuf, $history) = @_;

		#check parameters
		return FALSE unless $uri;
		unless ($uri->exists){
			&fct_show_status_message( 1, $uri->to_string . " " . $d->get("not found") );		
			return FALSE;
		}
		
		#check mime type
		#~ my $mime_type = Gnome2::VFS->get_mime_type_for_name( $uri->to_string );
		#~ unless ($mime_type && &fct_check_valid_mime_type($mime_type)){
			#~ #not a supported mime type
			#~ my $response = $sd->dlg_error_message( 
				#~ sprintf ( $d->get(  "Error while opening image %s." ), "'" . $uri->to_string . "'" ) ,
				#~ $d->get( "There was an error opening the image." ),
				#~ undef, undef, undef,
				#~ undef, undef, undef,
				#~ $d->get( "MimeType not supported." )
			#~ );
			#~ &fct_show_status_message( 1, $uri->to_string . " " . $d->get("not supported") );		
			#~ return FALSE;					
		#~ }

		#add to recentmanager
		$rmanager->add_item($uri->to_string);

		#append a page to notebook using with label == filename
		my ( $second, $minute, $hour ) = localtime();
		my $theTime = sprintf("%02d:%02d:%02d", $hour, $minute, $second);
		my $key     = "[" . &fct_get_latest_tab_key . "] - $theTime";

		#store the history object
		if(defined $history && $history->get_history){
			$session_screens{$key}->{'history'} = $history;
			$session_start_screen{'first_page'}->{'history'} = $history;	 
			$session_screens{$key}->{'history_timestamp'} = time;
		}

		#setup tab label (thumb, preview etc.)
		my $hbox_tab_label = Gtk2::HBox->new( FALSE, 0 );
		my $close_icon = Gtk2::Image->new_from_icon_name( 'gtk-close', 'menu' );

		$session_screens{$key}->{'tab_icon'} = Gtk2::Image->new;

		#setup tab label
		my $tab_close_button = Gtk2::Button->new;
		$tab_close_button->set_relief('none');
		$tab_close_button->set_image($close_icon);
		$tab_close_button->set_name('tab-close-button');
		
		#customize the button style
		Gtk2::Rc->parse_string (
			"style 'tab-close-button-style' {
				 GtkWidget::focus-padding = 0
				 GtkWidget::focus-line-width = 0
				 xthickness = 0
				 ythickness = 0
			 }
			 widget '*.tab-close-button' style 'tab-close-button-style'"
		);
				
		my $tab_label = Gtk2::Label->new($key);
		$hbox_tab_label->pack_start( $session_screens{$key}->{'tab_icon'}, FALSE, TRUE, 1 );
		$hbox_tab_label->pack_start( $tab_label, FALSE, FALSE, 1 );
		$hbox_tab_label->pack_start( Gtk2::HBox->new, TRUE, TRUE, 1 );
		$hbox_tab_label->pack_start( $tab_close_button, FALSE, FALSE, 1 );
		$hbox_tab_label->show_all;

		#and append page with label == key
		my $new_index = $notebook->append_page( &fct_create_tab( $key, FALSE ), $hbox_tab_label );
		$session_screens{$key}->{'tab_label'} = $hbox_tab_label;
		$session_screens{$key}->{'tab_child'} = $notebook->get_nth_page($new_index);
		$tab_close_button->signal_connect( clicked => sub { &fct_remove($key); } );

		$notebook->set_current_page($new_index);

		if ( &fct_update_tab( $key, $pixbuf, $uri ) ) {
			#setup a filemonitor, so we get noticed if the file changed
			&fct_add_file_monitor($key);			
		}

		return $key;
	}

	sub fct_add_file_monitor {
		my $key = shift;

		$session_screens{$key}->{'changed'} = FALSE;
		$session_screens{$key}->{'deleted'} = FALSE;
		$session_screens{$key}->{'created'} = FALSE;

		my $result;
		if(defined $session_screens{$key}->{'uri'}){	
			( $result, $session_screens{$key}->{'handle'} ) = Gnome2::VFS::Monitor->add(
				$session_screens{$key}->{'uri'}->to_string,
				'file',
				sub {
					my $handle = shift;
					my $file1  = shift;
					my $file2  = shift;
					my $event  = shift;
					my $key    = shift;

					print $event. " - $key\n" if $sc->get_debug;

					if ( $event eq 'deleted' ) {
						
						$handle->cancel;
						
						if(exists $session_screens{$key}){
							$session_screens{$key}->{'deleted'} = TRUE;
							$session_screens{$key}->{'changed'} = TRUE;
							&fct_update_tab($key);
						}

					} elsif ( $event eq 'changed' ) {

						print $session_screens{$key}->{'uri'}->to_string . " - " . $event . "\n" if $sc->get_debug;
						$session_screens{$key}->{'changed'} = TRUE;
						&fct_update_tab($key);
					
					}

				},
				$key
			);
		}else{
			$result = 'error-generic';	
		}
		
		#show error dialog when installing the file
		#monitor failed
		unless ($result eq 'ok'){
			$sd->dlg_error_message( Gnome2::VFS->result_to_string($result), $d->get("Failed") );		
			return FALSE;
		}

		return TRUE;
	}

	sub fct_control_signals {
		my $action = shift;
		
		my $sensitive = undef;
		if($action eq 'block'){
			
			$sensitive = FALSE;
		
			#block signals
			$SIG{USR1}  = 'IGNORE';
			$SIG{USR2}  = 'IGNORE';
			$SIG{RTMIN} = 'IGNORE';
			$SIG{RTMAX} = 'IGNORE';
		
			#and block status icon handler
			if ( $tray && $tray->isa('Gtk2::StatusIcon') ) {
				if($tray->signal_handler_is_connected($tray->{'hid'})){
					$tray->signal_handler_block($tray->{'hid'});
				}
				if($tray->signal_handler_is_connected($tray->{'hid2'})){
					$tray->signal_handler_block($tray->{'hid2'});
				}
			}elsif($tray){
				if($tray_box->signal_handler_is_connected($tray_box->{'hid'})){
					$tray_box->signal_handler_block($tray_box->{'hid'});
				}
			}		

		}elsif($action eq 'unblock'){

			$sensitive = TRUE;

			#attach signal-handler again
			$SIG{USR1}  = sub { &evt_take_screenshot( 'global_keybinding', 'raw' ) };
			$SIG{USR2}  = sub { &evt_take_screenshot( 'global_keybinding', 'window' ) };
			$SIG{RTMIN} = sub { &evt_take_screenshot( 'global_keybinding', 'select' ) };
			$SIG{RTMAX} = sub { &evt_take_screenshot( 'global_keybinding', 'section' ) };
				
			#and unblock status icon handler
			if ( $tray && $tray->isa('Gtk2::StatusIcon') ) {
				if($tray->signal_handler_is_connected($tray->{'hid'})){
					$tray->signal_handler_unblock($tray->{'hid'});
				}
				if($tray->signal_handler_is_connected($tray->{'hid2'})){
					$tray->signal_handler_unblock($tray->{'hid2'});
				}
			}elsif($tray){
				if($tray_box->signal_handler_is_connected($tray_box->{'hid'})){
					$tray_box->signal_handler_unblock($tray_box->{'hid'});
				}
			}	

		}	
		
		#enable/disable controls
		if($st->{_select} && $sm->{_menuitem_selection}){
			#menu
			$sm->{_menuitem_selection}->set_sensitive($sensitive);
			$sm->{_menuitem_full}->set_sensitive($sensitive);
			$sm->{_menuitem_window}->set_sensitive($sensitive);
			$sm->{_menuitem_section}->set_sensitive($sensitive);
			$sm->{_menuitem_menu}->set_sensitive($sensitive);
			$sm->{_menuitem_tooltip}->set_sensitive($sensitive);
			$sm->{_menuitem_web}->set_sensitive($sensitive) if ($gnome_web_photo);
			$sm->{_menuitem_iclipboard}->set_sensitive($sensitive);
			
			#toolbar
			$st->{_select}->set_sensitive($sensitive);
			$st->{_full}->set_sensitive($sensitive);
			$st->{_window}->set_sensitive($sensitive);
			$st->{_section}->set_sensitive($sensitive);
			$st->{_menu}->set_sensitive($sensitive);
			$st->{_tooltip}->set_sensitive($sensitive);
			$st->{_web}->set_sensitive($sensitive) if ($gnome_web_photo);
					
			#special case: redoshot (toolbar and menu)
			if(&fct_get_last_capture){
				$st->{_redoshot}->set_sensitive($sensitive);
				$sm->{_menuitem_redoshot}->set_sensitive($sensitive);
			}

		}
		
		return TRUE;
	}

	sub fct_control_main_window {
		my $mode 	= shift;
		
		#default value for present is TRUE
		my $present = TRUE;
		$present = shift if @_;
		
		#this is an unusual method for raising the window
		#to the top within the stacking order (z-axis)
		#but it works best here
		if($mode eq 'show' && $is_hidden && $present){

			#move window to saved position
			$window->move( $window->{x}, $window->{y} ) if (defined $window->{x} && defined $window->{y});

			$window->show_all;
			$window->window->focus(Gtk2->get_current_event_time) if defined $window->window;
			$window->present;
			#set flag
			$is_hidden = FALSE;

			#toolbar->set_show_arrow is FALSE at startup
			#to automatically adjust the main window width
			#we change the setting to TRUE if it is still false, 
			#so the window/toolbar is resizable again
			if($st->{_toolbar}){
				unless($st->{_toolbar}->get_show_arrow){
					$st->{_toolbar}->set_show_arrow(TRUE);
					#add a small margin
					my ($rw, $rh) = $window->get_size;
					$window->resize($rw+50, $rh);
				}
			}

		}elsif($mode eq 'hide'){

			#save current position of main window
			( $window->{x}, $window->{y} ) = $window->get_position;

			$window->hide;
			
			$is_hidden = TRUE;
			
		}
		
		return TRUE;
	}

	sub fct_create_tab {
		my ( $key, $is_all ) = @_;

		my $vbox            = Gtk2::VBox->new( FALSE, 0 );
		my $vbox_tab        = Gtk2::VBox->new( FALSE, 0 );
		my $vbox_tab_event  = Gtk2::EventBox->new;

		unless ($is_all) {

			#Gtk2::ImageView - empty at first
			$session_screens{$key}->{'image'} = Gtk2::ImageView->new();
			$session_screens{$key}->{'image'}->set_interpolation ('tiles');
			$session_screens{$key}->{'image'}->set_show_frame(FALSE);	

			#Sets how the view should draw transparent parts of images with an alpha channel		
			my $color = $trans_custom_btn->get_color;
			my $color_string = sprintf( "%02x%02x%02x", $color->red / 257, $color->green / 257, $color->blue / 257 );
			
			my $mode;
			if ( $trans_check->get_active ) {
				$mode = 'grid';	
			}elsif ( $trans_custom->get_active ) {
				$mode = 'color';
			}elsif ( $trans_backg->get_active ) {		
				$mode = 'color';
				my $bg = $window->get_style->bg('normal');
				$color_string = sprintf( "%02x%02x%02x", $bg->red / 257, $bg->green / 257, $bg->blue / 257 );			
			}

			$session_screens{$key}->{'image'}->set_transp($mode, hex $color_string);
						
			#Gtk2::ImageView::ScrollWin packaged in a Gtk2::ScrolledWindow
			my $scrolled_window_image = Gtk2::ImageView::ScrollWin->new($session_screens{$key}->{'image'});
			#~ my $scrolled_window_image = Gtk2::ScrolledWindow->new;
			#~ $scrolled_window_image->set_policy( 'automatic', 'automatic' );
			#~ $scrolled_window_image->add_with_viewport(Gtk2::ImageView::ScrollWin->new($session_screens{$key}->{'image'}));

			#WORKAROUND
			#upstream bug
			#http://trac.bjourne.webfactional.com/ticket/21						
			#left  => zoom in
			#right => zoom out
			$session_screens{$key}->{'image'}->signal_connect('scroll-event', sub{
				my ($view, $ev) = @_;		
				if($ev->direction eq 'left'){
					$ev->direction('up');
				}elsif($ev->direction eq 'right'){
					$ev->direction('down');
				}
				return FALSE;
			});
			
			$session_screens{$key}->{'image'}->signal_connect('button-press-event', sub{
				my ($view, $ev) = @_;
				if($ev->button == 1 && $ev->type eq '2button-press'){
					&fct_zoom_best;	
					return TRUE;
				}else{
					return FALSE;	
				}					
			});

			#dnd
			$session_screens{$key}->{'image'}->drag_source_set('button1-mask', ['copy'], {'target' => "text/uri-list", 'flags' => [], 'info' => 0});
			$session_screens{$key}->{'image'}->signal_connect ('drag-data-get', sub{ 
				my ($widget, $context, $data, $info, $time) = @_;	
				if(exists $session_screens{$key}->{'uri'} && defined $session_screens{$key}->{'uri'}){
					$data->set($data->target, 8, $session_screens{$key}->{'uri'}->to_string);
				}
			 });
			
			#maybe we need to disable dnd to allow scrolling
			$session_screens{$key}->{'image'}->signal_connect('expose-event', sub{
				my ($view) = @_;
				my $block_dnd = FALSE;
				foreach ($scrolled_window_image->get_children){
					if($_ =~ /Scrollbar/){
						if($_->visible){
							$block_dnd = TRUE;
							last;
						}
					}
				}
				if($block_dnd){
					$view->drag_source_unset;
				}else{
					$view->drag_source_set('button1-mask', ['copy'], {'target' => "text/uri-list", 'flags' => [], 'info' => 0});
				}	
			});
			
			$vbox_tab->pack_start( $scrolled_window_image, TRUE, TRUE, 0 );

			$vbox->pack_start_defaults($vbox_tab);
			
			#pack vbox into an event box so we can listen
			#to various key and button events
			$vbox_tab_event->add($vbox);
			$vbox_tab_event->show_all;
			$vbox_tab_event->signal_connect('button-press-event', \&evt_tab_button_press, $key);
			
			return $vbox_tab_event;

		} else {

			#create iconview for session
			$session_start_screen{'first_page'}->{'model'} = Gtk2::ListStore->new( 'Gtk2::Gdk::Pixbuf', 'Glib::String', 'Glib::String' );
			$session_start_screen{'first_page'}->{'view'} = Gtk2::IconView->new_with_model($session_start_screen{'first_page'}->{'model'});
			#~ $session_start_screen{'first_page'}->{'view'}->set_orientation('horizontal');
			$session_start_screen{'first_page'}->{'view'}->set_item_width (150);
			$session_start_screen{'first_page'}->{'view'}->set_pixbuf_column(0);
			$session_start_screen{'first_page'}->{'view'}->set_text_column(1);
			$session_start_screen{'first_page'}->{'view'}->set_selection_mode('multiple');
			#~ $session_start_screen{'first_page'}->{'view'}->set_columns(0);
			$session_start_screen{'first_page'}->{'view'}->signal_connect( 'selection-changed', \&evt_iconview_sel_changed,    'sel_changed' );
			$session_start_screen{'first_page'}->{'view'}->signal_connect( 'item-activated',    \&evt_iconview_item_activated, 'item_activated' );

			#pack into scrolled window
			my $scrolled_window_view = Gtk2::ScrolledWindow->new;
			$scrolled_window_view->set_policy( 'automatic', 'automatic' );
			$scrolled_window_view->set_shadow_type('in');
			$scrolled_window_view->add($session_start_screen{'first_page'}->{'view'});

			#add an event box to show a context menu on right-click
			my $view_event = Gtk2::EventBox->new;
			$view_event->add($scrolled_window_view);
			$view_event->signal_connect( 'button-press-event', \&evt_iconview_button_press, $session_start_screen{'first_page'}->{'view'} );

			#dnd
			$session_start_screen{'first_page'}->{'view'}->enable_model_drag_source('button1-mask', ['copy'], {'target' => "text/uri-list", 'flags' => [], 'info' => 0});
			$session_start_screen{'first_page'}->{'view'}->signal_connect ('drag-data-get', sub{ 
				my ($widget, $context, $data, $info, $time) = @_;
							
				my $target_list;
				$session_start_screen{'first_page'}->{'view'}->selected_foreach(
					sub {
						my ( $view, $path ) = @_;
						my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
						if ( defined $iter ) {
							my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
							if(exists $session_screens{$key}->{'uri'} && defined $session_screens{$key}->{'uri'}){
								$target_list .= $session_screens{$key}->{'uri'}->to_string."\n";
							}
						}
					}
				);
				
				$data->set($data->target, 8, $target_list);

			 });

			$vbox_tab->pack_start( $view_event, TRUE, TRUE, 0 );

			$vbox->pack_start_defaults($vbox_tab);
			$vbox->show_all;

			return $vbox;

		}

	}

	sub fct_save_settings {
		my ($profilename) = @_;

		#settings file
		my $settingsfile = "$ENV{ HOME }/.shutter/settings.xml";
		if ( defined $profilename ) {
			$settingsfile = "$ENV{ HOME }/.shutter/profiles/$profilename.xml"
				if ( $profilename ne "" );
		}

		#session file
		my $sessionfile = "$ENV{ HOME }/.shutter/session.xml";

		#accounts file
		my $accountsfile = "$ENV{ HOME }/.shutter/accounts.xml";
		if ( defined $profilename ) {
			$accountsfile = "$ENV{ HOME }/.shutter/profiles/$profilename\_accounts.xml"
				if ( $profilename ne "" );
		}

		#we store the version info, so we know if there was a new version installed
		#when starting new version we clear the cache on first startup
		$settings{'general'}->{'app_version'} = $sc->get_version . $sc->get_rev;

		$settings{'general'}->{'last_profile'}      = $combobox_settings_profiles->get_active;
		$settings{'general'}->{'last_profile_name'} = $combobox_settings_profiles->get_active_text || "";

		#menu
		$settings{'gui'}->{'btoolbar_active'} = $sm->{_menuitem_btoolbar}->get_active();

		#recently used
		$settings{'recent'}->{'ruu_tab'}       = $sc->get_ruu_tab;
		$settings{'recent'}->{'ruu_hosting'}   = $sc->get_ruu_hosting;
		$settings{'recent'}->{'ruu_places'}    = $sc->get_ruu_places;
		$settings{'recent'}->{'ruu_u1'}        = $sc->get_ruu_u1;

		#main
		$settings{'general'}->{'filetype'} 		   = $combobox_type->get_active;
		$settings{'general'}->{'quality'}  		   = $scale->get_value();
		$settings{'general'}->{'filename'} 		   = $filename->get_text();
		$settings{'general'}->{'folder'} 		   = $saveDir_button->get_current_folder();
		$settings{'general'}->{'save_auto'}       = $save_auto_active->get_active();
		$settings{'general'}->{'save_ask'}        = $save_ask_active->get_active();
		$settings{'general'}->{'image_autocopy'}  = $image_autocopy_active->get_active();
		$settings{'general'}->{'fname_autocopy'}  = $fname_autocopy_active->get_active();
		$settings{'general'}->{'no_autocopy'} 	   = $no_autocopy_active->get_active();
		$settings{'general'}->{'cursor'}		      = $cursor_active->get_active();
		$settings{'general'}->{'delay'}			   = $delay->get_value();

		#wrksp -> submenu
		$settings{'general'}->{'current_monitor_active'} = $current_monitor_active->get_active;

		$settings{'general'}->{'selection_tool'} = 1
			if $tool_advanced->get_active;
		$settings{'general'}->{'selection_tool'} = 2
			if $tool_simple->get_active;

		#determining timeout
		if($gnome_web_photo){
			my $web_menu = $st->{_web}->get_menu;
			my @timeouts = $web_menu->get_children;
			my $timeout  = undef;
			foreach (@timeouts) {

				if ( $_->get_active ) {
					$timeout = $_->get_children->get_text;
					$timeout =~ /([0-9]+)/;
					$timeout = $1;
				}
			}
			$settings{'general'}->{'web_timeout'} = $timeout;
		}	

		my $model         = $progname->get_model();
		my $progname_iter = $progname->get_active_iter();

		if ( defined $progname_iter ) {
			my $progname_value = $model->get_value( $progname_iter, 1 );
			$settings{'general'}->{'prog'} = $progname_value;
		}

		#actions
		$settings{'general'}->{'prog_active'}			= $progname_active->get_active();
		$settings{'general'}->{'im_colors'}				= $combobox_im_colors->get_active();
		$settings{'general'}->{'im_colors_active'}		= $im_colors_active->get_active();
		$settings{'general'}->{'thumbnail'}				= $thumbnail->get_value();
		$settings{'general'}->{'thumbnail_active'}		= $thumbnail_active->get_active();
		$settings{'general'}->{'bordereffect'}			= $bordereffect->get_value();
		$settings{'general'}->{'bordereffect_active'}	= $bordereffect_active->get_active();
		my $bcolor = $bordereffect_cbtn->get_color;
		$settings{'general'}->{'bordereffect_col'}		= sprintf( "#%02x%02x%02x", $bcolor->red / 257, $bcolor->green / 257, $bcolor->blue / 257 );

		#advanced
		$settings{'general'}->{'zoom_active'} 	   = $zoom_active->get_active();
		$settings{'general'}->{'as_help_active'}   = $as_help_active->get_active();
		$settings{'general'}->{'asel_x'} 	   	   = $asel_size3->get_value();
		$settings{'general'}->{'asel_y'} 	       = $asel_size4->get_value();
		$settings{'general'}->{'asel_w'} 	       = $asel_size1->get_value();
		$settings{'general'}->{'asel_h'} 	       = $asel_size2->get_value();
		$settings{'general'}->{'border'}           = $border_active->get_active();
		$settings{'general'}->{'visible_windows'}  = $visible_windows_active->get_active();
		$settings{'general'}->{'menu_delay'}  	   = $menu_delay->get_value();
		$settings{'general'}->{'menu_waround'}     = $menu_waround_active->get_active();
		$settings{'general'}->{'web_width'}        = $combobox_web_width->get_active();

		#imageview
		$settings{'general'}->{'trans_check'}      = $trans_check->get_active();
		$settings{'general'}->{'trans_custom'}     = $trans_custom->get_active();
		my $tcolor = $trans_custom_btn->get_color;
		$settings{'general'}->{'trans_custom_col'} = sprintf( "#%02x%02x%02x", $tcolor->red / 257, $tcolor->green / 257, $tcolor->blue / 257 );
		$settings{'general'}->{'trans_backg'}      = $trans_backg->get_active();

		#behavior
		$settings{'general'}->{'autohide'}         = $hide_active->get_active();
		$settings{'general'}->{'autohide_time'}    = $hide_time->get_value();
		$settings{'general'}->{'present_after'}    = $present_after_active->get_active();
		$settings{'general'}->{'close_at_close'}   = $close_at_close_active->get_active();
		$settings{'general'}->{'notify_after'}     = $notify_after_active->get_active();
		$settings{'general'}->{'notify_timeout'}   = $notify_timeout_active->get_active();
		$settings{'general'}->{'notify_ptimeout'}  = $notify_ptimeout_active->get_active();
		$settings{'general'}->{'notify_agent'}     = $combobox_ns->get_active();
		$settings{'general'}->{'ask_on_delete'}    = $ask_on_delete_active->get_active();
		$settings{'general'}->{'delete_on_close'}  = $delete_on_close_active->get_active();

		#keybindings
		$settings{'general'}->{'keybinding'}       = $keybinding_active->get_active();
		$settings{'general'}->{'keybinding_sel'}   = $keybinding_sel_active->get_active();
		$settings{'general'}->{'keybinding_mode'}  = $combobox_keybinding_mode->get_active();
		$settings{'general'}->{'capture_key'}      = $capture_key->get_text();
		$settings{'general'}->{'capture_sel_key'}  = $capture_sel_key->get_text();

		#ftp upload
		$settings{'general'}->{'ftp_uri'}      = $ftp_remote_entry->get_text();
		$settings{'general'}->{'ftp_mode'}     = $ftp_mode_combo->get_active();
		$settings{'general'}->{'ftp_username'} = $ftp_username_entry->get_text();
		$settings{'general'}->{'ftp_password'} = $ftp_password_entry->get_text();
		$settings{'general'}->{'ftp_wurl'} 	   = $ftp_wurl_entry->get_text();
		
		#plugins
		foreach my $plugin_key ( sort keys %plugins ) {	
			$settings{'plugins'}->{$plugin_key}->{'name'}        = $plugin_key;
			$settings{'plugins'}->{$plugin_key}->{'binary'}      = $plugins{$plugin_key}->{'binary'};
			$settings{'plugins'}->{$plugin_key}->{'name_plugin'} = $plugins{$plugin_key}->{'name'};
			$settings{'plugins'}->{$plugin_key}->{'category'}    = $plugins{$plugin_key}->{'category'};
			
			#keep newlines => switch them to <![CDATA[<br>]]> tags
			#the load routine does it the other way round
			my $temp_tooltip = $plugins{$plugin_key}->{'tooltip'};
			$temp_tooltip =~ s/\n/\<\!\[CDATA\[\<br\>\]\]\>/g;
			$settings{'plugins'}->{$plugin_key}->{'tooltip'}     = $temp_tooltip;
			$settings{'plugins'}->{$plugin_key}->{'lang'}        = $plugins{$plugin_key}->{'lang'};
			$settings{'plugins'}->{$plugin_key}->{'recent'}      = $plugins{$plugin_key}->{'recent'} if defined $plugins{$plugin_key}->{'recent'};
		}

		#settings
		eval {
			my ( $tmpfh, $tmpfilename ) = tempfile(UNLINK => 1);
			XMLout( \%settings, OutputFile => $tmpfilename);
			#and finally move the file
			mv($tmpfilename, $settingsfile);
		};
		if ($@) {
			$sd->dlg_error_message( $@, $d->get("Settings could not be saved!") );
		}else{
			&fct_show_status_message( 1, $d->get("Settings saved successfully!") );
		}

		#we need to clean the hashkeys, so they become parseable
		my %clean_files;
		my $counter = 0;
		foreach ( Sort::Naturally::nsort(keys %session_screens) ) {

			next unless exists $session_screens{$_}->{'long'};

			#8 leading zeros to counter
			$counter = sprintf( "%08d", $counter );
			if ( $shf->file_exists( $session_screens{$_}->{'long'} ) ) {
				$clean_files{ "file" . $counter }{'filename'} = $session_screens{$_}->{'long'};
				$counter++;
			}
		}
		
		#session
		eval {
			my ( $tmpfh, $tmpfilename ) = tempfile(UNLINK => 1);	
			XMLout( \%clean_files, OutputFile => $tmpfilename );
			#and finally move the file
			mv($tmpfilename, $sessionfile);
		};
		if ($@) {
			$sd->dlg_error_message( $@, $d->get("Session could not be saved!") );
		}

		#accounts
		my %clean_accounts;
		foreach ( keys %accounts ) {
			$clean_accounts{$_}->{'host'} 			= $accounts{$_}->{'host'};
			$clean_accounts{$_}->{'password'} 		= $accounts{$_}->{'password'};
			$clean_accounts{$_}->{'username'} 		= $accounts{$_}->{'username'};
		}

		eval {
			my ( $tmpfh, $tmpfilename ) = tempfile(UNLINK => 1);	
			XMLout( \%clean_accounts, OutputFile => $tmpfilename );
			#and finally move the file
			mv($tmpfilename, $accountsfile);
		};
		if ($@) {
			$sd->dlg_error_message( $@, $d->get("Account-settings could not be saved!") );
		}

		#keybindings
		&fct_save_bindings($capture_key->get_text, $capture_sel_key->get_text);	

		return TRUE;
	}

	sub fct_save_bindings {
		my $key 	= shift;
		my $skey 	= shift;
		
		#~ #COMPIZ VIA DBus	
		#~ my $bus		= undef;
		#~ my $compiz 	= undef;
		#~ my $cs 		= undef;
		#~ my $cs_k  	= undef;
		#~ my $cws     = undef;
		#~ my $cws_k  	= undef;
		
		#~ eval{
			#~ $bus = Net::DBus->find;
			#~ 
			#~ #Get a handle to the compiz service
			#~ $compiz = $bus->get_service("org.freedesktop.compiz");
	#~ 
			#~ # Get the relevant objects object
			#~ $cs = $compiz->get_object("/org/freedesktop/compiz/gnomecompat/allscreens/command_screenshot",
										 #~ "org.freedesktop.compiz");
			#~ 
			#~ $cs_k = $compiz->get_object("/org/freedesktop/compiz/gnomecompat/allscreens/run_command_screenshot_key",
										 #~ "org.freedesktop.compiz");
	#~ 
			#~ $cws = $compiz->get_object("/org/freedesktop/compiz/gnomecompat/allscreens/command_window_screenshot",
										 #~ "org.freedesktop.compiz");
			#~ 
			#~ $cws_k = $compiz->get_object("/org/freedesktop/compiz/gnomecompat/allscreens/run_command_window_screenshot_key",
										 #~ "org.freedesktop.compiz");
		#~ };
		#~ if($@){
			#~ warn "WARNING: DBus connection to org.freedesktop.compiz failed --> setting keyboard shortcuts may not work when using compiz\n\n";
			#~ warn $@ . "\n\n";
		#~ }

		#GCONF
		my $client        = Gnome2::GConf::Client->get_default;

		#global error handler function catch just the unchecked error
		$client->set_error_handling('handle-unreturned');
		$client->signal_connect(unreturned_error => sub {
			my ($client, $error) = @_;
			warn $error; # is a Glib::Error
		});	
		
		my $shortcut_full = "/apps/metacity/global_keybindings/run_command_screenshot";
		my $shortcut_sel  = "/apps/metacity/global_keybindings/run_command_window_screenshot";
		my $command_full  = "/apps/metacity/keybinding_commands/command_screenshot";
		my $command_sel   = "/apps/metacity/keybinding_commands/command_window_screenshot";

		eval{
			#set values
			if ( $keybinding_active->get_active() ) {
				
				$client->set( $command_full, { type => 'string', value => "$shutter_path --full" } );
				$client->set( $shortcut_full, { type  => 'string', value => $key } );
				
				#compiz if available
				#~ if(defined $cs && defined $cs_k){
					#~ $cs->set(dbus_string "$shutter_path --full");
					#~ 
					#~ #currently not needed because keys are copied from gconf
					#~ $cs_k->set(dbus_string $key);
				#~ }
				
			} else {
				
				$client->set( $command_full,  { type => 'string', value => 'gnome-screenshot', } );
				$client->set( $shortcut_full, { type => 'string', value => 'Print', } );

				#compiz if available
				#~ if(defined $cs && defined $cs_k){
					#~ $cs->set(dbus_string 'gnome-screenshot');
					#~ 
					#~ #currently not needed because keys are copied from gconf
					#~ $cs_k->set(dbus_string 'Print');
				#~ }	

			}
			
			if ( $keybinding_sel_active->get_active() ) {
				
				my $mode = undef;
				if ( $combobox_keybinding_mode->get_active() == 0 ) {
					$mode = "--selection";
				} elsif ( $combobox_keybinding_mode->get_active() == 1 ) {
					$mode = "--window";
				} elsif ( $combobox_keybinding_mode->get_active() == 2 ) {
					$mode = "--section";
				} else {
					$mode = "--window";
				}
				
				$client->set( $command_sel, { type  => 'string', value => "$shutter_path $mode" } );
				$client->set( $shortcut_sel, { type  => 'string', value => $skey } );
				
				#compiz if available
				#~ if(defined $cws && defined $cws_k){
					#~ $cws->set(dbus_string "$shutter_path $mode");
					#~ 
					#~ #currently not needed because keys are copied from gconf
					#~ $cws_k->set(dbus_string $skey);
				#~ }

			} else {
				
				$client->set( $command_sel, { type  => 'string', value => 'gnome-screenshot --window' } );
				$client->set( $shortcut_sel, { type => 'string', value => '<Alt>Print' } );
				
				#compiz if available
				#~ if(defined $cws && defined $cws_k){
					#~ $cws->set(dbus_string 'gnome-screenshot --window');
	#~ 
					#~ #currently not needed because keys are copied from gconf
					#~ $cws_k->set(dbus_string '<Alt>Print');
				#~ }	
				
			}

		};
		if($@){
			#show error message
			#~ my $response = $sd->dlg_error_message( 
				#~ $@,
				#~ $d->get(  "There was an error configuring the keybindings." )
			#~ );				
		}

		return TRUE;
	}

	sub fct_load_settings {
		my ( $data, $profilename ) = @_;

		#settings file
		my $settingsfile = "$ENV{ HOME }/.shutter/settings.xml";
		$settingsfile = "$ENV{ HOME }/.shutter/profiles/$profilename.xml"
			if ( defined $profilename );

		my $settings_xml;
		if ( $shf->file_exists($settingsfile) ) {
			eval {
				$settings_xml = XMLin( IO::File->new($settingsfile) );

				if ( $data eq 'profile_load' ) {

					#migration from gscrot to shutter
					#maybe we can drop this in future releases
					# 0 := jpeg
					# 1 := png
					unless(defined $settings_xml->{'general'}->{'app_version'}){
						if($settings_xml->{'general'}->{'filetype'} == 0){
							$combobox_type->set_active($int_jpeg);			
						}elsif($settings_xml->{'general'}->{'filetype'} == 1){
							$combobox_type->set_active($int_png);		
						}
					#shutter
					}else{
						$combobox_type->set_active($settings_xml->{'general'}->{'filetype'});	
					}
										
					#main
					$scale->set_value( $settings_xml->{'general'}->{'quality'} );
					utf8::decode $settings_xml->{'general'}->{'filename'};
					$filename->set_text( $settings_xml->{'general'}->{'filename'} );

					utf8::decode $settings_xml->{'general'}->{'folder'};
					$saveDir_button->set_current_folder( $settings_xml->{'general'}->{'folder'} );
					
					$save_auto_active->set_active( $settings_xml->{'general'}->{'save_auto'} );
					$save_ask_active->set_active( $settings_xml->{'general'}->{'save_ask'} );
					
					$image_autocopy_active->set_active( $settings_xml->{'general'}->{'image_autocopy'} );
					$fname_autocopy_active->set_active( $settings_xml->{'general'}->{'fname_autocopy'} );
					$no_autocopy_active->set_active( $settings_xml->{'general'}->{'no_autocopy'} );

					$cursor_active->set_active( $settings_xml->{'general'}->{'cursor'} );
					$delay->set_value( $settings_xml->{'general'}->{'delay'} );

					#FIXME
					#this is a dirty hack to force the setting to be enabled in session tab
					#at the moment i simply dont know why the filechooser "caches" the old value
					# => weird...
					$settings_xml->{'general'}->{'folder_force'} = TRUE;

					#wrksp -> submenu
					$current_monitor_active->set_active( $settings_xml->{'general'}->{'current_monitor_active'} );

					#selection tool -> submenu
					$tool_advanced->set_active(TRUE)
						if $settings_xml->{'general'}->{'selection_tool'} == 1;
					$tool_simple->set_active(TRUE)
						if $settings_xml->{'general'}->{'selection_tool'} == 2;

					#determining timeout
					my $web_menu = $st->{_web}->get_menu;
					my @timeouts = $web_menu->get_children;
					my $timeout  = undef;
					foreach (@timeouts) {
						$timeout = $_->get_children->get_text;
						$timeout =~ /([0-9]+)/;
						$timeout = $1;
						if ( $settings_xml->{'general'}->{'web_timeout'} == $timeout ) {
							$_->set_active(TRUE);
						}
					}

					#action settings
					my $model = $progname->get_model;
					utf8::decode $settings_xml->{'general'}->{'prog'};
					$model->foreach( \&fct_iter_programs, $settings_xml->{'general'}->{'prog'} );
					$progname_active->set_active( $settings_xml->{'general'}->{'prog_active'} );
					
					$im_colors_active->set_active( $settings_xml->{'general'}->{'im_colors_active'} );
					$combobox_im_colors->set_active( $settings_xml->{'general'}->{'im_colors'} );
					
					$thumbnail->set_value( $settings_xml->{'general'}->{'thumbnail'} );
					$thumbnail_active->set_active( $settings_xml->{'general'}->{'thumbnail_active'} );

					$bordereffect->set_value( $settings_xml->{'general'}->{'bordereffect'} );
					$bordereffect_active->set_active( $settings_xml->{'general'}->{'bordereffect_active'} );
					if(defined $settings_xml->{'general'}->{'bordereffect_col'}){
						$bordereffect_cbtn->set_color(Gtk2::Gdk::Color->parse($settings_xml->{'general'}->{'bordereffect_col'}));
					}
					
					#advanced settings
					$zoom_active->set_active( $settings_xml->{'general'}->{'zoom_active'} );
					
					$as_help_active->set_active( $settings_xml->{'general'}->{'as_help_active'} );
					
					$asel_size3->set_value($settings_xml->{'general'}->{'asel_x'});
					$asel_size4->set_value($settings_xml->{'general'}->{'asel_y'});
					$asel_size1->set_value($settings_xml->{'general'}->{'asel_w'});
					$asel_size2->set_value($settings_xml->{'general'}->{'asel_h'});
			
					$border_active->set_active( $settings_xml->{'general'}->{'border'} );
					$visible_windows_active->set_active( $settings_xml->{'general'}->{'visible_windows'} );
					$menu_waround_active->set_active( $settings_xml->{'general'}->{'menu_waround'} );
					$menu_delay->set_value( $settings_xml->{'general'}->{'menu_delay'} );
					$combobox_web_width->set_active( $settings_xml->{'general'}->{'web_width'} );

					#imageview
					$trans_check->set_active( $settings_xml->{'general'}->{'trans_check'} );
					$trans_custom->set_active( $settings_xml->{'general'}->{'trans_custom'} );
					if(defined $settings_xml->{'general'}->{'trans_custom_col'}){
						$trans_custom_btn->set_color(Gtk2::Gdk::Color->parse($settings_xml->{'general'}->{'trans_custom_col'}));
					}
					$trans_backg->set_active( $settings_xml->{'general'}->{'trans_backg'} );

					#behavior
					$hide_active->set_active( $settings_xml->{'general'}->{'autohide'} );
					$hide_time->set_value( $settings_xml->{'general'}->{'autohide_time'} );
					$present_after_active->set_active( $settings_xml->{'general'}->{'present_after'} );
					$close_at_close_active->set_active( $settings_xml->{'general'}->{'close_at_close'} );
					$notify_after_active->set_active( $settings_xml->{'general'}->{'notify_after'} );
					$notify_timeout_active->set_active( $settings_xml->{'general'}->{'notify_timeout'} );
					$notify_ptimeout_active->set_active( $settings_xml->{'general'}->{'notify_ptimeout'} );
					$combobox_ns->set_active( $settings_xml->{'general'}->{'notify_agent'} );
					$ask_on_delete_active->set_active( $settings_xml->{'general'}->{'ask_on_close'} );
					$delete_on_close_active->set_active( $settings_xml->{'general'}->{'delete_on_close'} );

					#keybindings
					$keybinding_active->set_active( $settings_xml->{'general'}->{'keybinding'} );
					$keybinding_sel_active->set_active( $settings_xml->{'general'}->{'keybinding_sel'} );

					utf8::decode $settings_xml->{'general'}->{'capture_key'};
					utf8::decode $settings_xml->{'general'}->{'capture_sel_key'};
					
					$capture_key->set_text( $settings_xml->{'general'}->{'capture_key'} );
					$capture_sel_key->set_text( $settings_xml->{'general'}->{'capture_sel_key'} );
					$combobox_keybinding_mode->set_active( $settings_xml->{'general'}->{'keybinding_mode'} );

					#ftp_upload
					utf8::decode $settings_xml->{'general'}->{'ftp_uri'};
					utf8::decode $settings_xml->{'general'}->{'ftp_mode'};
					utf8::decode $settings_xml->{'general'}->{'ftp_username'};
					utf8::decode $settings_xml->{'general'}->{'ftp_password'};
					utf8::decode $settings_xml->{'general'}->{'ftp_wurl'};
					
					$ftp_remote_entry->set_text( $settings_xml->{'general'}->{'ftp_uri'} );
					$ftp_mode_combo->set_active( $settings_xml->{'general'}->{'ftp_mode'} );
					$ftp_username_entry->set_text( $settings_xml->{'general'}->{'ftp_username'} );
					$ftp_password_entry->set_text( $settings_xml->{'general'}->{'ftp_password'} );
					$ftp_wurl_entry->set_text( $settings_xml->{'general'}->{'ftp_wurl'} );

					#load account data from profile
					&fct_load_accounts($profilename);
					if ( defined $accounts_tree ) {
						&fct_load_accounts_tree;
						$accounts_tree->set_model($accounts_model);
						&fct_set_model_accounts($accounts_tree);
					}

				#endif profile load
				}else{

					#recently used
					$sc->set_ruu_tab($settings_xml->{'recent'}->{'ruu_tab'});
					$sc->set_ruu_hosting($settings_xml->{'recent'}->{'ruu_hosting'});
					$sc->set_ruu_places($settings_xml->{'recent'}->{'ruu_places'});
					$sc->set_ruu_u1($settings_xml->{'recent'}->{'ruu_u1'});
								
					#we store the version info, so we know if there was a new version installed
					#when starting new version we clear the cache on first startup
					if (defined $settings_xml->{'general'}->{'app_version'}){
						if($sc->get_version . $sc->get_rev ne $settings_xml->{'general'}->{'app_version'}){
							$sc->set_clear_cache(TRUE);
						}	
					}else{
						$sc->set_clear_cache(TRUE);
					}

					#get plugins from cache unless param is set to ignore it
					if ( !$sc->get_clear_cache ) {

						foreach my $plugin_key ( sort keys %{ $settings_xml->{'plugins'} } ) {
							utf8::decode $settings_xml->{'plugins'}->{$plugin_key}->{'binary'};

							#check if plugin still exists in filesystem
							if ( $shf->file_exists( $settings_xml->{'plugins'}->{$plugin_key}->{'binary'} ) ) {
								
								#restore newlines <![CDATA[<br>]]> tags => \n
								$settings_xml->{'plugins'}->{$plugin_key}->{'tooltip'} =~ s/\<\!\[CDATA\[\<br\>\]\]\>/\n/g;
								
								utf8::decode $settings_xml->{'plugins'}->{$plugin_key}->{'name_plugin'};
								utf8::decode $settings_xml->{'plugins'}->{$plugin_key}->{'category'};
								utf8::decode $settings_xml->{'plugins'}->{$plugin_key}->{'tooltip'};
								utf8::decode $settings_xml->{'plugins'}->{$plugin_key}->{'lang'};
								$plugins{$plugin_key}->{'binary'}   = $settings_xml->{'plugins'}->{$plugin_key}->{'binary'};
								$plugins{$plugin_key}->{'name'}     = $settings_xml->{'plugins'}->{$plugin_key}->{'name_plugin'};
								$plugins{$plugin_key}->{'category'} = $settings_xml->{'plugins'}->{$plugin_key}->{'category'};
								$plugins{$plugin_key}->{'tooltip'}  = $settings_xml->{'plugins'}->{$plugin_key}->{'tooltip'};
								$plugins{$plugin_key}->{'lang'}     = $settings_xml->{'plugins'}->{$plugin_key}->{'lang'} || "shell";
								$plugins{$plugin_key}->{'recent'}   = $settings_xml->{'plugins'}->{$plugin_key}->{'recent'};
							}
							
						}#endforeach

					}#endif plugins from cache

				}
				
			};
			if ($@) {
				$sd->dlg_error_message( $@, $d->get("Settings could not be restored!") );
				unlink $settingsfile;
			}else{
				&fct_show_status_message( 1, $d->get("Settings loaded successfully") );				
			}			

		} #endif file exists

		return $settings_xml;
	}

	sub fct_get_program_model {
		my $model = Gtk2::ListStore->new( 'Gtk2::Gdk::Pixbuf', 'Glib::String', 'Glib::Scalar' );

		my $traytheme = $sc->get_theme;

		#add Shutter's built-in editor to the list
		if($goocanvas){
			my $tray_pixbuf = undef;
			my $tray_name = 'shutter';
			if ( $traytheme->has_icon( $tray_name ) ) {
				my ( $iw, $ih ) = Gtk2::IconSize->lookup('menu');
				eval{
					$tray_pixbuf = $traytheme->load_icon( $tray_name, $ih, 'generic-fallback' );
				};
				if($@){
					print "\nWARNING: Could not load icon $tray_name: $@\n";
					$tray_pixbuf = undef;
				}						
			}	
			$model->set( $model->append, 0, $tray_pixbuf, 1, $d->get("Built-in Editor"), 2, 'shutter-built-in' );
		}

		#Get all installed apps
		#FIXME - use png as default mime type (is this clever enough?)
		my ( $default, @mapps ) = File::MimeInfo::Applications::mime_applications('image/png');
		
		#currently we use File::MimeInfo::Applications and Gnome2::VFS::Mime::Type
		#because of the following error
		#
		#libgnomevfs-WARNING **: 
		#Cannot call gnome_vfs_mime_application_get_icon 
		#with a GNOMEVFSMimeApplication structure constructed 
		#by the deprecated application registry 
		my $mime_type = Gnome2::VFS::Mime::Type->new ('image/png');
		my @apps = $mime_type->get_all_applications();

		#get some other apps that may be capable (e.g. browsers)
		my $mime_type_fallback = Gnome2::VFS::Mime::Type->new ('text/html');
		foreach ($mime_type_fallback->get_all_applications()){
			my $already_in_list = FALSE;
			foreach my $existing_app (@apps){
				if($_->{'id'} eq $existing_app->{'id'}){
					$already_in_list = TRUE;
					last;
				}
			}
			push @apps, $_ unless $already_in_list;
		}
			
		#no app determined!
		unless (scalar @apps && scalar @mapps){
			return $model;			
		}

		#find icon and app
		#we use File::DesktopEntry instead of the Gnome one
		#for opening files
		foreach my $mapp (@mapps){
			foreach my $app (@apps){

				#~ print "checking ", $app->{'name'}, " for preferences\n";

				#ignore Shutter's desktop entry
				next if $app->{'id'} eq 'shutter.desktop';
				
				$app->{'name'} = $shf->utf8_decode($app->{'name'});
				
				#FIXME - kde apps do not support the freedesktop standards (.desktop files)
				#we simply cut the kde* / kde4* substring here
				#is it possible to get the wrong app if there 
				#is the kde3 and the kde4 version of an app installed?
				#
				#I think so ;-)
				$app->{'id'} =~ s/^(kde4|kde)-//g;
				if($mapp->{'file'} =~ m/$app->{'id'}/){
					my $tray_pixbuf = undef;
					my $tray_name = $mapp->Icon;
					if($tray_name){
						#cut image formats
						$tray_name =~ s/(.png|.svg|.gif|.jpeg|.jpg)//g;				
						if ( $traytheme->has_icon( $tray_name ) ) {
							my ( $iw, $ih ) = Gtk2::IconSize->lookup('menu');
							eval{
								$tray_pixbuf = $traytheme->load_icon( $tray_name, $ih, 'generic-fallback' );
							};
							if($@){
								print "\nWARNING: Could not load icon $tray_name: $@\n";
								$tray_pixbuf = undef;	
							}						
						}
					}else{
						$tray_pixbuf = undef;
					}
					$model->set( $model->append, 0, $tray_pixbuf, 1, $app->{'name'}, 2, $mapp );
					last;
				}	
			}
		}

		return $model;
	}

	sub fct_load_accounts {
		my ($profilename) = @_;

		#accounts file
		my $accountsfile = "$ENV{ HOME }/.shutter/accounts.xml";
		$accountsfile = "$ENV{ HOME }/.shutter/profiles/$profilename\_accounts.xml"
			if ( defined $profilename );

		my $accounts_xml;
		eval { $accounts_xml = XMLin( IO::File->new($accountsfile) ) if $shf->file_exists($accountsfile); };

		if ($@) {
			$sd->dlg_error_message( $@, $d->get("Account-settings could not be restored!") );
			unlink $accountsfile;
		}

		#account data, load defaults if nothing is set
		unless ( exists( $accounts_xml->{'imageshack.us'} ) ) {
			$accounts{'imageshack.us'}->{host}     = "imageshack.us";
			$accounts{'imageshack.us'}->{username} = "";
			$accounts{'imageshack.us'}->{password} = "";
		} else {
			$accounts{'imageshack.us'}->{host}     = $accounts_xml->{'imageshack.us'}->{host};
			$accounts{'imageshack.us'}->{username} = $accounts_xml->{'imageshack.us'}->{username};
			$accounts{'imageshack.us'}->{password} = $accounts_xml->{'imageshack.us'}->{password};
		}

		$accounts{'imageshack.us'}->{register} = "http://my.imageshack.us/registration/";

		unless ( exists( $accounts_xml->{'imagebanana.com'} ) ) {
			$accounts{'imagebanana.com'}->{host}     = "imagebanana.com";
			$accounts{'imagebanana.com'}->{username} = "";
			$accounts{'imagebanana.com'}->{password} = "";
		} else {
			$accounts{'imagebanana.com'}->{host}     = $accounts_xml->{'imagebanana.com'}->{host};
			$accounts{'imagebanana.com'}->{username} = $accounts_xml->{'imagebanana.com'}->{username};
			$accounts{'imagebanana.com'}->{password} = $accounts_xml->{'imagebanana.com'}->{password};
		}

		$accounts{'imagebanana.com'}->{register} = "http://www.imagebanana.com/register/";

		foreach ( keys %accounts ) {
			utf8::decode $accounts{$_}->{'host'};
			utf8::decode $accounts{$_}->{'username'};
			utf8::decode $accounts{$_}->{'password'};
			$accounts{$_}->{'register_color'} = "blue";
			$accounts{$_}->{'register_text'}  = $accounts{$_}->{register};
		}

		return TRUE;
	}

	sub fct_drop_handler {
		my ($widget, $context, $x, $y, $selection, $info, $time) = @_;
		my $type = $selection->target->name;
		my $data = $selection->data;
		return unless $type eq 'text/uri-list';

		my @files = grep defined($_), split /[\r\n]+/, $data;
		
		my @valid_files;
		foreach(@files){
			my $mime_type = Gnome2::VFS->get_mime_type_for_name( $_ );
			if($mime_type && &fct_check_valid_mime_type($mime_type)){
				push @valid_files, $_;
			}
		}
		
		#open all valid files
		if(@valid_files){
			&fct_open_files(@valid_files);
		}else{
			$context->finish (0, 0, $time);	
			return FALSE;
		}
		
		$context->finish (1, 0, $time);
		return TRUE;
	}

	sub fct_check_valid_mime_type {
		my $mime_type = shift;

		foreach ( Gtk2::Gdk::Pixbuf->get_formats ) {		
			foreach ( @{ $_->{mime_types} } ) {
				return TRUE if $_ eq $mime_type;
				last;
			}
		}
		
		return FALSE;
	}

	sub fct_open_files {
		my (@new_files) = @_;

		return FALSE if scalar(@new_files) < 1;

		my $open_dialog = Gtk2::MessageDialog->new( $window, [qw/modal destroy-with-parent/], 'info', 'close', $d->get("Loading files") );

		$open_dialog->set_title("Shutter");

		$open_dialog->set( 'secondary-text' => $d->get("Please wait while your selected files are being loaded into Shutter") . "." );

		$open_dialog->signal_connect( response => sub { $_[0]->destroy } );

		my $open_progress = Gtk2::ProgressBar->new;
		$open_progress->set_no_show_all(TRUE);
		$open_progress->set_ellipsize('middle');
		$open_progress->set_orientation('left-to-right');
		$open_progress->set_fraction(0);

		$open_dialog->vbox->add($open_progress);

		#do not show when min at startup
		unless ( $sc->get_min ) {
			$open_progress->show;
			$open_dialog->show_all;
		}

		my $num_files = scalar(@new_files);
		my $count     = 0;
		foreach (@new_files) {

			my $new_uri = Gnome2::VFS::URI->new ($shf->utf8_decode(Gnome2::VFS->unescape_string($_)));

			next if &fct_is_uri_in_session($new_uri, TRUE);

			#refresh the progressbar
			$count++;
			$open_progress->set_fraction( $count / $num_files );
			$open_progress->set_text($new_uri->to_string);

			#refresh tray icon
			if ( $tray && $tray->isa('Gtk2::StatusIcon') ) {
				$tray->set_blinking(TRUE);
			}

			#refresh gui
			&fct_update_gui;

			#do the real work
			if(&fct_integrate_screenshot_in_notebook( $new_uri )){
				&fct_show_status_message( 1, $new_uri->to_string . " " . $d->get("opened") );	
			}
		}
		$open_dialog->response('ok');

		#refresh tray icon
		if ( $tray && $tray->isa('Gtk2::StatusIcon') ) {
			$tray->set_blinking(FALSE);
		}

		return TRUE;
	}

	sub fct_is_uri_in_session {
		my $uri  = shift;
		my $jump = shift;
		
		return FALSE unless $uri;
		
		foreach my $key ( keys %session_screens ) {
			if ( exists $session_screens{$key}->{'uri'} ) {
				if($uri->equal($session_screens{$key}->{'uri'})){
					if ( exists $session_screens{$key}->{'tab_child'} ) {
						if($jump){
							$notebook->set_current_page($notebook->page_num($session_screens{$key}->{'tab_child'}));
						}
						return TRUE;
					}	
				}	
			}
		}
		
		return FALSE;	
	}

	sub fct_load_session {

		#session file
		my $sessionfile = "$ENV{ HOME }/.shutter/session.xml";

		eval {
			my $session_xml = XMLin( IO::File->new($sessionfile) )
				if $shf->file_exists($sessionfile);

			return FALSE if scalar( keys %{$session_xml} ) < 1;

			my $restore_dialog = Gtk2::MessageDialog->new( $window, [qw/modal destroy-with-parent/], 'info', 'close', 'none' );

			$restore_dialog->set( 'text' => $d->get("Restoring session") );

			$restore_dialog->set( 'secondary-text' => $d->get("Please wait while your saved session is being restored") . "." );

			$restore_dialog->signal_connect( response => sub { $_[0]->destroy } );

			my $restore_progress = Gtk2::ProgressBar->new;
			$restore_progress->set_no_show_all(TRUE);
			$restore_progress->set_ellipsize('middle');
			$restore_progress->set_orientation('left-to-right');
			$restore_progress->set_fraction(0);

			$restore_dialog->vbox->add($restore_progress);

			#do not show when min at startup
			unless ( $sc->get_min ) {
				$restore_progress->show;
				$restore_dialog->show_all;
				$restore_progress->grab_focus;
			}

			my $num_files = scalar( keys %{$session_xml} );
			my $count     = 0;
			foreach ( sort keys %{$session_xml} ) {

				#refresh the progressbar
				$count++;
				$restore_progress->set_fraction( $count / $num_files );
				$restore_progress->set_text( ${$session_xml}{$_}{'filename'} );

				#refresh tray icon
				if ( $tray && $tray->isa('Gtk2::StatusIcon') ) {
					$tray->set_blinking(TRUE);
				}

				#refresh gui
				&fct_update_gui;

				#do the real work
				my $new_uri = Gnome2::VFS::URI->new( ${$session_xml}{$_}{'filename'} );
				&fct_integrate_screenshot_in_notebook( $new_uri );

			}
		
			$restore_dialog->response('ok');

			#refresh tray icon
			if ( $tray && $tray->isa('Gtk2::StatusIcon') ) {
				$tray->set_blinking(FALSE);			
			}
			
		};
		if ($@) {
			$sd->dlg_error_message( $@, $d->get("Session could not be restored!") );

			unlink $sessionfile;

			#refresh tray icon
			if ( $tray && $tray->isa('Gtk2::StatusIcon') ) {
				$tray->set_blinking(FALSE);
			}

		}

		return TRUE;
	}

	sub fct_screenshot_exists {
		my ($key) = @_;

		#check if file still exists
		unless ( $session_screens{$key}->{'uri'}->exists ) {
			&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("not found") );
			return FALSE;
		}
		return TRUE;
	}

	sub fct_delete {
		my $key 	= shift;
		my $action 	= shift;

		#close current tab (unless $key is provided or close_all)
		unless(defined $action && $action eq 'menu_close_all'){
			$key = &fct_get_current_file unless $key;
		}

		#single file
		if ($key) {
			
			if($ask_on_delete_active->get_active){
				my $response = $sd->dlg_question_message(
					"",
					sprintf( $d->get("Are you sure you want to move %s to the trash?"), "'" . $session_screens{$key}->{'long'} . "'" ),
					'gtk-cancel', $d->get("Move to _Trash"), 
				);		
				return FALSE unless $response == 20;
			}	

			if ( $session_screens{$key}->{'uri'}->exists ) {

				#cancel handle
				if ( exists $session_screens{$key}->{'handle'} ) {
					
					$session_screens{$key}->{'handle'}->cancel;
				}

				#find trash directory
				my $trash_uri = Gnome2::VFS->find_directory( Gnome2::VFS::URI->new( $ENV{'HOME'} ), 'trash', TRUE, TRUE, 755 );

				#move to trash
				$trash_uri = $trash_uri->append_file_name( $session_screens{$key}->{'short'} );
				#~ my $result = $session_screens{$key}->{'uri'}->move( $trash_uri, TRUE ) if $session_screens{$key}->{'uri'}->exists;
				#move to trash (Xfer because the Trash might be on a different filesystem)
				my $result = Gnome2::VFS::Xfer->uri ($session_screens{$key}->{'uri'}, $trash_uri, 'default', 'abort', 'replace', sub{ return TRUE });
				unless ($result eq 'ok'){
					$sd->dlg_error_message( Gnome2::VFS->result_to_string($result), $d->get("Failed") );
				}
				
				#and finally delete the file
				$result = $session_screens{$key}->{'uri'}->unlink;
				unless ($result eq 'ok'){
					$sd->dlg_error_message( Gnome2::VFS->result_to_string($result), $d->get("Failed") );
				}			
				
			}

			$notebook->remove_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );    #delete tab
			&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("deleted") )
				if defined( $session_screens{$key}->{'long'} );

			if(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
				$session_start_screen{'first_page'}->{'model'}->remove( $session_screens{$key}->{'iter'} );
			}

			#unlink undo and redo files
			&fct_unlink_tempfiles($key);

			delete $session_screens{$key};

			$window->show_all unless $is_hidden;

			#session tab
		} else {

			if($ask_on_delete_active->get_active){
				
				#any files selected?
				my $selected = FALSE;
				$session_start_screen{'first_page'}->{'view'}->selected_foreach(
					sub {
						my ( $view, $path ) = @_;
						my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
						if ( defined $iter ) {
							$selected = TRUE;
						}
					}
				);			
				
				if($selected){
					my $response = $sd->dlg_question_message(
						"",
						$d->get("Are you sure you want to move the selected files to the trash?"),
						'gtk-cancel', $d->get("Move to _Trash"), 
						);		
					return FALSE unless $response == 20;
				}else{
					&fct_show_status_message( 1, $d->get("No screenshots selected") );
					return FALSE;				
				}
			}

			my @to_delete;
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						$notebook->remove_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );
						
						if ( $session_screens{$key}->{'uri'}->exists ) {

							#cancel handle
							if ( exists $session_screens{$key}->{'handle'} ) {
								
								$session_screens{$key}->{'handle'}->cancel;
							}

							#find trash directory
							my $trash_uri = Gnome2::VFS->find_directory( Gnome2::VFS::URI->new( $ENV{'HOME'} ), 'trash', TRUE, TRUE, 755 );

							#move to trash
							$trash_uri = $trash_uri->append_file_name( $session_screens{$key}->{'short'} );
							#~ $session_screens{$key}->{'uri'}->move( $trash_uri, TRUE );
							#move to trash (Xfer because the Trash might be on a different filesystem)
							my $result = Gnome2::VFS::Xfer->uri ($session_screens{$key}->{'uri'}, $trash_uri, 'default', 'abort', 'replace', sub{ return TRUE });
							unless ($result eq 'ok'){
								$sd->dlg_error_message( Gnome2::VFS->result_to_string($result), $d->get("Failed") );
							}
							
							#and finally delete the file
							$result = $session_screens{$key}->{'uri'}->unlink;
							unless ($result eq 'ok'){
								$sd->dlg_error_message( Gnome2::VFS->result_to_string($result), $d->get("Failed") );
							}	

						}

						#copy to array
						#we delete the files from hash and model 
						#when exiting the sub 
						push @to_delete, $key; 

					}
				},
				undef
			);

			if(scalar @to_delete == 0){
				&fct_show_status_message( 1, $d->get("No screenshots selected") );
				return FALSE;
			}
					
			#delete from hash and model
			foreach my $key (@to_delete){
				if(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
					$session_start_screen{'first_page'}->{'model'}->remove( $session_screens{$key}->{'iter'} );
				}

				#unlink undo and redo files
				&fct_unlink_tempfiles($key);

				delete $session_screens{$key};
			}

			&fct_show_status_message( 1, $d->get("Selected screenshots deleted") );

			$window->show_all unless $is_hidden;

		}

		&fct_update_info_and_tray();

		return TRUE;
	}

	sub fct_remove {
		my $key 	= shift;
		my $action 	= shift;

		#close current tab (unless $key is provided or close_all)
		unless(defined $action && $action eq 'menu_close_all'){
			$key = &fct_get_current_file unless $key;
		}

		#single file
		if ($key) {

			#delete instead of remove
			if($delete_on_close_active->get_active){
				&fct_delete($key);
				return FALSE;	
			}

			if ( exists $session_screens{$key}->{'handle'} ) {

				#cancel handle
				$session_screens{$key}->{'handle'}->cancel;
			}

			$notebook->remove_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );    #delete tab
			&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("removed from session") )
				if defined( $session_screens{$key}->{'long'} );

			if(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
				$session_start_screen{'first_page'}->{'model'}->remove( $session_screens{$key}->{'iter'} );
			}

			#unlink undo and redo files
			&fct_unlink_tempfiles($key);

			delete $session_screens{$key};

			$window->show_all unless $is_hidden;

		} else {

			#delete instead of remove
			if($delete_on_close_active->get_active){
				&fct_delete(undef, 'menu_close_all');
				return FALSE;	
			}
			
			my @to_remove;
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						$notebook->remove_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );

						if ( exists $session_screens{$key}->{'handle'} ) {

							#cancel handle
							$session_screens{$key}->{'handle'}->cancel;
						}

						#copy to array
						#we remove the files from hash and model 
						#when exiting the sub 
						push @to_remove, $key; 

					}
				},
				undef
			);

			if(scalar @to_remove == 0){
				&fct_show_status_message( 1, $d->get("No screenshots selected") );
				return FALSE;
			}

			#delete from hash and model
			foreach my $key (@to_remove){
				if(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
					$session_start_screen{'first_page'}->{'model'}->remove( $session_screens{$key}->{'iter'} );
				}
				
				#unlink undo and redo files
				&fct_unlink_tempfiles($key);
				
				delete $session_screens{$key};
			}

			&fct_show_status_message( 1, $d->get("Selected screenshots removed") );

			$window->show_all unless $is_hidden;

		}

		&fct_update_info_and_tray();

		return TRUE;
	}

	sub fct_update_gui {

		while ( Gtk2->events_pending ) {
			Gtk2->main_iteration;
		}
		Gtk2::Gdk->flush;

		return TRUE;
	}

	sub fct_clipboard_import {

		my $image = $clipboard->wait_for_image;
		if(defined $image){
					
			#determine current file type (name - description)
			$combobox_type->get_active_text =~ /(.*) -/;
			my $filetype_value = $1;
			unless ($filetype_value) {
				$sd->dlg_error_message( $d->get("No valid filetype specified"), $d->get("Failed") );
				&fct_control_main_window ('show');
				return FALSE;
			}

			#create tempfile
			my ( $tmpfh, $tmpfilename ) = tempfile(UNLINK => 1);
			$tmpfilename .= ".".$filetype_value;
			
			#save pixbuf to tempfile and integrate it
			if($sp->save_pixbuf_to_file($image, $tmpfilename, $filetype_value)){		
				my $new_key = &fct_integrate_screenshot_in_notebook( Gnome2::VFS::URI->new($tmpfilename), $image );
			}
					
		}else{
			&fct_show_status_message( 1, $d->get("There is no image data in the clipboard to paste") );		
		}

		return TRUE;
	}

	sub fct_clipboard {
		my ($widget, $mode) = @_;

		my $key = &fct_get_current_file;
		
		#create shutter region object
		my $sr = Shutter::Geometry::Region->new();
		
		my @clipboard_array;

		#single file
		if ($key) {

			return FALSE unless &fct_screenshot_exists($key);
			push (@clipboard_array, $key);

		}else{

			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						push (@clipboard_array, $key);
					}
				},
				undef
			);

		}

		my $clipboard_string = undef;
		my $clipboard_region = Gtk2::Gdk::Region->new;
		my @pixbuf_array;
		my @rects_array;
		foreach my $key (@clipboard_array){

			if($mode eq 'image'){
				my $pixbuf = Gtk2::Gdk::Pixbuf->new_from_file($session_screens{$key}->{'long'});
				my $rect = Gtk2::Gdk::Rectangle->new($sr->get_clipbox($clipboard_region)->width, 0, $pixbuf->get_width, $pixbuf->get_height);
				$clipboard_region->union_with_rect($rect);
				push @pixbuf_array, $pixbuf;
				push @rects_array, $rect;
			}else{
				$clipboard_string .= $session_screens{$key}->{'long'}."\n";	
			}
						
		}
		
		if($clipboard_string){
			chomp $clipboard_string;
			$clipboard->set_text( $clipboard_string );		
			&fct_show_status_message( 1, $d->get("Selected filenames copied to clipboard") );
		}

		if($clipboard_region->get_rectangles){
			my $clipboard_image = Gtk2::Gdk::Pixbuf->new ('rgb', TRUE, 8, $sr->get_clipbox($clipboard_region)->width, $sr->get_clipbox($clipboard_region)->height);	
			$clipboard_image->fill(0x00000000);
			
			#copy images to the blank pixbuf
			my $rect_counter = 0;
			foreach my $pixbuf (@pixbuf_array){
				$pixbuf->copy_area (0, 0, $pixbuf->get_width, $pixbuf->get_height, $clipboard_image, $rects_array[$rect_counter]->x, 0);
				$rect_counter++;
			}
					
			$clipboard->set_image( $clipboard_image );
			&fct_show_status_message( 1, $d->get("Selected images copied to clipboard") );		
		}
		
		return TRUE;
	}

	sub fct_unlink_tempfiles {
		my $key = shift;
		
		foreach(@{$session_screens{$key}->{'undo'}}){
			unlink $_;
		}	

		foreach(@{$session_screens{$key}->{'redo'}}){
			unlink $_;
		}	
		
		return TRUE;
	}

	sub fct_undo {

		my $key = &fct_get_current_file;

		#single file
		if ($key) {

			return FALSE unless &fct_screenshot_exists($key);
			
			#push current version to redo
			#(current version is always the last element in the array)
			my $current_version = pop @{$session_screens{$key}->{'undo'}};
			push @{$session_screens{$key}->{'redo'}}, $current_version;				

			#and revert last version
			my $last_version = pop @{$session_screens{$key}->{'undo'}};
			if($last_version){

				#cancel handle
				if ( exists $session_screens{$key}->{'handle'} ) {
					$session_screens{$key}->{'handle'}->cancel;
				}

				if (cp($last_version, $session_screens{$key}->{'long'})){

					&fct_update_tab( $key, undef, $session_screens{$key}->{'uri'}, TRUE, 'gui' );
			
					&fct_show_status_message( 1, $d->get("Last action undone") );
					
					#delete last_version from filesystem
					unlink $last_version;
					
				}else{

					my $response = $sd->dlg_error_message(
						sprintf( $d->get(  "Error while copying last version (%s)."), "'" . $last_version . "'"),
						sprintf( $d->get(  "There was an error performing undo on %s."), "'" . $session_screens{$key}->{'long'} . "'" ),
						undef, undef, undef,
						undef, undef, undef,
						$@
					);	

					&fct_update_tab( $key, undef, $session_screens{$key}->{'uri'}, TRUE, 'clear' );
					
				}
				
				#setup a new filemonitor, so we get noticed if the file changed
				&fct_add_file_monitor($key);		

			}

		}
		return TRUE;
	}

	sub fct_redo {

		my $key = &fct_get_current_file;

		#single file
		if ($key) {

			return FALSE unless &fct_screenshot_exists($key);

			#and revert last version
			my $last_version = pop @{$session_screens{$key}->{'redo'}};
			#~ push @{$session_screens{$key}->{'undo'}}, $last_version;
				
			if($last_version){

				#cancel handle
				if ( exists $session_screens{$key}->{'handle'} ) {
					$session_screens{$key}->{'handle'}->cancel;
				}

				if (cp($last_version, $session_screens{$key}->{'long'})){
			
					&fct_update_tab( $key, undef, $session_screens{$key}->{'uri'}, TRUE, 'gui' );

					&fct_show_status_message( 1, $d->get("Last action redone") );

					#delete last_version from filesystem
					unlink $last_version;
					
				}else{

					my $response = $sd->dlg_error_message(
						sprintf( $d->get(  "Error while copying last version (%s)."), "'" . $last_version . "'"),
						sprintf( $d->get(  "There was an error performing redo on %s."), "'" . $session_screens{$key}->{'long'} . "'" ),
						undef, undef, undef,
						undef, undef, undef,
						$@
					);
					
					&fct_update_tab( $key, undef, $session_screens{$key}->{'uri'}, TRUE, 'clear' );		
			
				}
				
				#setup a new filemonitor, so we get noticed if the file changed
				&fct_add_file_monitor($key);	
				
			}
			
		}
		return TRUE;
	}

	sub fct_select_all {

		$session_start_screen{'first_page'}->{'view'}->select_all;

		return TRUE;
	}

	sub fct_plugin {

		my $key = &fct_get_current_file;

		my @plugin_array;

		#single file
		if ($key) {

			return FALSE unless &fct_screenshot_exists($key);

			unless ( keys %plugins > 0 ) {
				$sd->dlg_error_message( $d->get("No plugin installed"), $d->get("Failed") );
			} else {
				push( @plugin_array, $key );
				&dlg_plugin(@plugin_array);
			}

			#session tab
		} else {

			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						push( @plugin_array, $key );
					}

				},
				undef
			);
			&dlg_plugin(@plugin_array);
		}
		return TRUE;
	}

	sub fct_rename {

		my $key = &fct_get_current_file;

		my @rename_array;

		#single file
		if ($key) {

			return FALSE unless &fct_screenshot_exists($key);

			print "Renaming of file " . $session_screens{$key}->{'long'} . " started\n"
				if $sc->get_debug;
			push (@rename_array, $key);
		
		} else {
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						push (@rename_array, $key);
					}
				},
				undef
			);
		}

		&dlg_rename(@rename_array);

		return TRUE;
	}

	sub fct_draw {

		my $key = &fct_get_current_file;

		my @draw_array;

		#single file
		if ($key) {

			return FALSE unless &fct_screenshot_exists($key);
			push (@draw_array, $key);

		} else {
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						push (@draw_array, $key);
					}
				},
				undef
			);
		}

		#open drawing tool
		foreach my $key (@draw_array){
			my $drawing_tool = Shutter::Draw::DrawingTool->new($sc, $view_d, $selector_d, $dragger_d);
			$drawing_tool->show( $session_screens{$key}->{'long'}, $session_screens{$key}->{'filetype'}, $session_screens{$key}->{'mime_type'}, \%session_screens );		
		}

		#~ &fct_control_main_window ('show');

		return TRUE;
	}

	sub fct_take_screenshot {
		my ( $widget, $data, $folder_from_config ) = @_;

		print "\n$data was emitted by widget $widget\n"
			if $sc->get_debug;

		my $quality_value	= $scale->get_value();
		my $delay_value     = undef;
		
		#filename
		my $filename_value = $filename->get_text();
		
		#filetype
		my $filetype_value 	   = undef;
		
		#folder to save
		my $folder             = $saveDir_button->get_current_folder || $folder_from_config;
		
		#screenshot(pixbuf) and screenshot name
		my $screenshot         = undef;
		my $screenshooter      = undef;
		my $screenshot_name    = undef;
		my $thumbnail_ending   = "thumb";
			
		#determine current file type (name - description)
		$combobox_type->get_active_text =~ /(.*) -/;
		$filetype_value = $1;
		unless ($filetype_value) {
			$sd->dlg_error_message( $d->get("No valid filetype specified"), $d->get("Failed") );
			&fct_control_main_window ('show');
			return FALSE;
		}

		#delay
		#when capturing a menu or tooltip => disable delay (there is a dedicated delay property for this)
		unless ( $data eq "menu" || $data eq "tray_menu" || $data eq "tooltip" || $data eq "tray_tooltip" ){
			#~ if ( $delay_active->get_active ) {
			if ( $delay->get_value ) {
				$delay_value = int $delay->get_value;
			} else {
				$delay_value = 0;
			}
		}else{
			$delay_value = 0;
		}
		
		#prepare filename, parse wild-cards
		$filename_value = $shf->utf8_decode (strftime $filename_value , localtime);
		#remove "/" and "#"
		$filename_value =~ s/(\/|\#)/-/g;

		#get next filename (auto increment using a wild card or manually)
		my $uri = &fct_get_next_filename( $filename_value, $folder, $filetype_value );

		#no valid filename was determined, exit here
		unless($uri){
			my $response = $sd->dlg_error_message( 
				$d->get( "There was an error determining the filename." ),
				$d->get("Failed") 
			);		
			&fct_control_main_window ('show');
			return FALSE;
		}

		#fullscreen screenshot
		if ( $data eq "raw" || $data eq "tray_raw" ) {
			my $wnck_screen = Gnome2::Wnck::Screen->get_default;

			$screenshooter = Shutter::Screenshot::Workspace->new(
				$sc, $cursor_active->get_active,
				$delay_value, $notify_timeout_active->get_active, $wnck_screen->get_active_workspace,
				undef, undef, $current_monitor_active->get_active
			);
			
			$screenshot = $screenshooter->workspace();

		#window
		} elsif ( $data eq "window" || 
				  $data eq "tray_window" || 
				  $data eq "section" || 
				  $data eq "tray_section" || 
				  $data eq "menu" || 
				  $data eq "tray_menu" ||
				  $data eq "tooltip" || 
				  $data eq "tray_tooltip" ) {

			$screenshooter = Shutter::Screenshot::Window->new(
				$sc, $cursor_active->get_active, $delay_value, $notify_timeout_active->get_active,
				$border_active->get_active, $data, $is_hidden, 
				$visible_windows_active->get_active, $hide_time->get_value, $menu_waround_active->get_active
			);
			
			$screenshot = $screenshooter->window();

		#selection
		} elsif ( $data eq "select" || $data eq "tray_select" ) {

			if ( $tool_advanced->get_active ) {

				#~ my $zoom_size_factor = 1;
				#~ $zoom_size_factor = 2 if ( $zoom_size2->get_active );
				#~ $zoom_size_factor = 3 if ( $zoom_size3->get_active );
				
				$screenshooter = Shutter::Screenshot::SelectorAdvanced->new( 
					$sc, $cursor_active->get_active, 
					$delay_value, $notify_timeout_active->get_active, 
					$zoom_active->get_active, $hide_time->get_value,
					$as_help_active->get_active,
					$view, $selector, $dragger,
					$asel_size3->get_value, $asel_size4->get_value,
					$asel_size1->get_value, $asel_size2->get_value
				);
				
				$screenshot = $screenshooter->select_advanced();
				
			} else {

				#~ my $zoom_size_factor = 1;
				#~ $zoom_size_factor = 2 if ( $zoom_size2->get_active );
				#~ $zoom_size_factor = 3 if ( $zoom_size3->get_active );
				
				$screenshooter = Shutter::Screenshot::SelectorSimple->new( 
					$sc, $cursor_active->get_active, $delay_value, $notify_timeout_active->get_active, 
					$zoom_active->get_active, $hide_time->get_value 
				);
				
				$screenshot = $screenshooter->select_simple();

			}
			
		#web
		} elsif ( $data eq "web" || $data eq "tray_web" ) {
			
			my $website_width = 1024;
			if($combobox_web_width->get_active_text =~ /(\d+)/){
				$website_width = $1;
			}

			print "\nvirtual website width: $website_width\n"
				if $sc->get_debug;

			#determine timeout
			my $web_menu = $st->{_web}->get_menu;
			my @timeouts = $web_menu->get_children;
			my $timeout  = undef;
			foreach (@timeouts) {
				if ( $_->get_active ) {
					$timeout = $_->get_children->get_text;
					$timeout =~ /([0-9]+)/;
					$timeout = $1;
					print $timeout. "\n" if $sc->get_debug;
				}
			}
			
			$screenshooter = Shutter::Screenshot::Web->new($sc, $timeout, $filetype_value, $website_width);		 
			$screenshot = $screenshooter->dlg_website();
		
		#window by xid	
		} elsif ( $data =~ /^shutter_window_direct(.*)/ ) {
			
			my $xid = $1;
			print "Selected xid: $xid\n" if $sc->get_debug;

			$screenshooter = Shutter::Screenshot::WindowXid->new( 
				$sc, 
				$cursor_active->get_active, 
				$delay_value, 
				$notify_timeout_active->get_active, 
				$border_active->get_active,
				$hide_time->get_value,
			);
			
			$screenshot = $screenshooter->window_by_xid($xid);

		} elsif ( $data =~ /^shutter_wrksp_direct/ ) {
			
			#we need to handle different wm, e.g. metacity, compiz here
			my $selected_workspace = undef;
			my $vpx                = undef;
			my $vpy                = undef;

			#compiz
			if ( $data =~ /compiz(\d*)x(\d*)/ ) {
				$vpx = $1;
				$vpy = $2;
				print "Sel. Viewport: $vpx, $vpy\n" if $sc->get_debug;

			#metacity etc.
			} elsif ( $data =~ /shutter_wrksp_direct(.*)/ ) {
				$selected_workspace = $1;
				print "Sel. Workspace: $selected_workspace\n"
					if $sc->get_debug;
			#all workspaces		
			} elsif ( $data =~ /shutter_wrksp_all/ ) {
				print "Capturing all workspaces\n"
					if $sc->get_debug;
				$selected_workspace = 'all';	
			}

			$screenshooter = Shutter::Screenshot::Workspace->new( 
				$sc, $cursor_active->get_active, $delay_value, $notify_timeout_active->get_active, 
				$selected_workspace, $vpx, $vpy, $current_monitor_active->get_active 
			);
			
			if($selected_workspace eq 'all'){
				$screenshot = $screenshooter->workspaces();
			}else{
				$screenshot = $screenshooter->workspace();
			}

		} elsif ( $data eq "redoshot" ) {

			#~ my $key = &fct_get_last_capture;
			#~ if(defined $key && exists $session_screens{$key}->{'history'} && defined $session_screens{$key}->{'history'}){
				#~ $screenshooter = $session_screens{$key}->{'history'};
				#~ $screenshot = $screenshooter->redo_capture;
			#~ }else{			
				#~ $screenshot = 3;	
			#~ }		

			if($screenshooter = &fct_get_last_capture){
				#we need to handle menu and tooltip in a special way
				if($screenshooter->can('get_mode')){
					if(my $mode = $screenshooter->get_mode){
						if ( $mode eq "menu" || $mode eq "tray_menu" ) {
							$st->{_menu}->signal_emit('clicked');
							return FALSE;
						}elsif ( $mode eq "tooltip" || $mode eq "tray_tooltip" ) {
							$st->{_tooltip}->signal_emit('clicked');
							return FALSE;
						}else{
							$screenshot = $screenshooter->redo_capture;	
						}
					#window by xid
					}else{
						$screenshot = $screenshooter->redo_capture;
					}	
				}else{
					$screenshot = $screenshooter->redo_capture;
				}			
			}else{
				$screenshot = 3;
			}

		} elsif ( $data eq "redoshot_this" ) {
			
			#get current screenshot (current notebook page)
			my $key = &fct_get_current_file;
			#or get the selected screenshot in the view
			unless(defined $key){
				$session_start_screen{'first_page'}->{'view'}->selected_foreach(
					sub {
						my ( $view, $path ) = @_;
						my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
						if ( defined $iter ) {
							$key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						}
					},
					undef
				);				
			}
			
			if(defined $key && exists $session_screens{$key}->{'history'} && defined $session_screens{$key}->{'history'}){
				$screenshooter = $session_screens{$key}->{'history'};
				#we need to handle menu and tooltip in a special way
				if($screenshooter->can('get_mode')){
					if(my $mode = $screenshooter->get_mode){
						if ( $mode eq "menu" || $mode eq "tray_menu" ) {
							$st->{_menu}->signal_emit('clicked');
							return FALSE;
						}elsif ( $mode eq "tooltip" || $mode eq "tray_tooltip" ) {
							$st->{_tooltip}->signal_emit('clicked');
							return FALSE;
						}else{
							$screenshot = $screenshooter->redo_capture;	
						}
					#window by xid	
					}else{
						$screenshot = $screenshooter->redo_capture;
					}	
				}else{
					$screenshot = $screenshooter->redo_capture;
				}	
			}else{
				$screenshot = 3;
			}

		} else {
			#show error dialog
			my $response = $sd->dlg_error_message( 
				$d->get( "Triggered invalid screenshot action." ),
				$d->get( "Error while taking the screenshot." )
			);
				
			&fct_show_status_message( 1, $d->get("Error while taking the screenshot.") );
			&fct_control_main_window ('show');
			return FALSE;		
		}

		#screenshot was taken at this stage...
		#start postprocessing here

		#...successfully???
		#~ print "$sc, $screenshot, $data\n";
		my $error = Shutter::Screenshot::Error->new($sc, $screenshot, $data);
		if($error->is_error) {
			
			my ($response, $status_text) = $error->show_dialog($screenshooter->get_error_text);
			&fct_show_status_message( 1, $status_text );
			&fct_control_main_window ('show');
			return FALSE;
			
		} else {

			#we have to use the path (e.g. /home/username/file1.png)
			#so we can save the screenshot_properly
			$screenshot_name = $shf->utf8_decode(Gnome2::VFS->unescape_string($uri->get_path));
			#maybe / is set as uri (get_path returns undef)
			#in this case nothing is returned when using get_path
			#we use the directory name and the short name in this case
			#(anyway - most users won't have permissions to write to /)
			$screenshot_name = "/". $uri->extract_short_name unless $screenshot_name;
			
			print "Parsing wildcards for $screenshot_name\n"
				if $sc->get_debug;		
			
			#parse width and height
			my $swidth  = $screenshot->get_width;
			my $sheight = $screenshot->get_height;

			$screenshot_name =~ s/\$w/$swidth/g;
			$screenshot_name =~ s/\$h/$sheight/g;

			print "Parsed \$width and \$height: $screenshot_name\n"
				if $sc->get_debug;
				
			#parse profile name
			my $current_pname  = $combobox_settings_profiles->get_active_text;	
			$screenshot_name =~ s/\$profile/$current_pname/g;

			print "Parsed \$profile: $screenshot_name\n"
				if $sc->get_debug;

			#set name
			#e.g. window or workspace name		
			if(my $action_name = $screenshooter->get_action_name){
				utf8::decode $action_name;
				$action_name =~ s/(\/|\#)/-/g;
				$screenshot_name =~ s/\$name/$action_name/g;
				#no blanks (special wildcard)
				$action_name =~ s/\ //g;
				$screenshot_name =~ s/\$nb_name/$action_name/g;				
			}else{
				$screenshot_name =~ s/(\$name|\$nb_name)/unknown/g;
			}

			print "Parsed \$name: $screenshot_name\n"
				if $sc->get_debug;

			#update uri after parsing as well, so we can check if file exists for example
			$uri = Gnome2::VFS::URI->new ($screenshot_name);
					
			#maybe the uri already exists, so we have to append some digits (e.g. testfile01(0002).png)
			if ( $uri->exists ) {
				my $count = 1;
				my $new_filename = fileparse($shf->utf8_decode(Gnome2::VFS->unescape_string($uri->get_path)), qr/\.[^.]*/);
				
				print "Checking if filename already exists: " . $new_filename . "\n" if $sc->get_debug;
				
				my $existing_filename = $new_filename;
				while ( $uri->exists ) {
					$new_filename = $existing_filename . "(" . sprintf( "%03d", $count++ ) . ")";
					$uri 	= Gnome2::VFS::URI->new($folder);
					$uri    = $uri->append_string("$new_filename.$filetype_value");
					print "Checking new uri after parsing: " . $uri->to_string . "\n" if $sc->get_debug;
				}
			}
					
			#we have to update the path again
			$shf->utf8_decode(Gnome2::VFS->unescape_string($uri->get_path));
			
			#ask for filename and folder
			if($save_ask_active->get_active){

				print "Asking for filename\n"
					if $sc->get_debug;

				if($screenshot_name = &dlg_save_as(undef, undef, $screenshot_name, $screenshot, $quality_value)){
					if($screenshot_name eq 'user_cancel'){
						&fct_show_status_message( 1, $d->get("Capture aborted by user") );
						&fct_control_main_window('show', $present_after_active->get_active);
						return FALSE;		
					}else{
						#update uri after saving, so we can check if file exists for example
						$uri = Gnome2::VFS::URI->new ($screenshot_name);					
					}
				}else{
					&fct_control_main_window ('show');
					return FALSE;					
				}
				
			}else{	

				#bordereffect
				if ( $bordereffect_active->get_active ) {

					print "Adding border effect to $screenshot_name\n"
						if $sc->get_debug;

					my $pbuf_border = Shutter::Pixbuf::Border->new($sc);
					$screenshot = $pbuf_border->create_border($screenshot, $bordereffect->get_value, $bordereffect_cbtn->get_color);
				}
			
				print "Trying to save file to $screenshot_name\n"
					if $sc->get_debug;
		
				#finally save pixbuf
				unless ($sp->save_pixbuf_to_file($screenshot, $screenshot_name, $filetype_value, $quality_value)){
					&fct_control_main_window ('show');
					return FALSE;			
				}
			
			}

		}    #end screenshot successfull
		
		if ( $uri->exists ) {

			#quantize
			if ( $im_colors_active->get_active ) {
				my $colors;
				if($combobox_im_colors->get_active == 0){
					$colors = 16;
				}elsif($combobox_im_colors->get_active == 1){
					$colors = 64;
				}elsif($combobox_im_colors->get_active == 2){
					$colors = 256;
				}
				$screenshot = &fct_imagemagick_perform( 'reduce_colors', $screenshot_name, $colors );
			}

			#generate the thumbnail
			my $screenshot_thumbnail      = undef;
			my $screenshot_thumbnail_name = undef;
			if ( $thumbnail_active->get_active ) {

				#calculate size
				my $twidth  = int( $screenshot->get_width *  ( $thumbnail->get_value / 100 ) );
				my $theight = int( $screenshot->get_height * ( $thumbnail->get_value / 100 ) );

				#create thumbail
				$screenshot_thumbnail = Gtk2::Gdk::Pixbuf->new_from_file_at_scale( $screenshot_name, $twidth, $theight, TRUE );

				#save path of thumbnail
				my ($name, $folder, $ext) = fileparse( $screenshot_name, qr/\.[^.]*/ );
				$screenshot_thumbnail_name = $folder . "/$name-$thumbnail_ending.$filetype_value";

				#parse wild cards
				$screenshot_thumbnail_name =~ s/\$w/$twidth/g;
				$screenshot_thumbnail_name =~ s/\$h/$theight/g;

				print "Trying to save file to $screenshot_thumbnail_name\n"
					if $sc->get_debug;

				#finally save pixbuf
				unless($sp->save_pixbuf_to_file($screenshot_thumbnail, $screenshot_thumbnail_name, $filetype_value, $quality_value)){
					&fct_control_main_window ('show');
					return FALSE;			
				}

			}

			#integrate it into the notebook
			my $new_key_screenshot = &fct_integrate_screenshot_in_notebook( $uri, $screenshot, $screenshooter );

			#thumbnail as well if present
			my $new_key_screenshot_thumbnail = &fct_integrate_screenshot_in_notebook( Gnome2::VFS::URI->new($screenshot_thumbnail_name), $screenshot_thumbnail )
				if $thumbnail_active->get_active;
			
			#copy to clipboard
			if(!$no_autocopy_active->get_active()) {
			
				#image_autocopy to clipboard if configured
				if ( $image_autocopy_active->get_active() ) {
					$clipboard->set_image($screenshot);
				}
				
				#filename autocopy to clipboard if configured
				if ( $fname_autocopy_active->get_active() ) {
					$clipboard->set_text($screenshot_name);
				}

			}

			#open screenshot with configured program
			if ( $progname_active->get_active ) {
				my $model         	= $progname->get_model();
				my $progname_iter 	= $progname->get_active_iter();
				if ($progname_iter) {
					my $progname_value 	= $model->get_value( $progname_iter, 2 );
					my $appname_value 	= $model->get_value( $progname_iter, 1 );
					&fct_open_with_program($progname_value, $appname_value);
				}
			}
			print "screenshot successfully saved to $screenshot_name!\n"
				if $sc->get_debug;
			&fct_show_status_message( 1, "$session_screens{$new_key_screenshot}->{'short'} " . $d->get("saved") );
			
			#show pop-up notification
			if($notify_after_active->get_active){
				my $notify 	= $sc->get_notification_object;
				$notify->show( $d->get("Screenshot saved"), $screenshot_name );
			}

		} else {
			#show error dialog
			my $response = $sd->dlg_error_message( 
				sprintf($d->get( "The filename %s could not be verified. Maybe it contains unsupported characters." ), "'" . $screenshot_name . "'"),
				$d->get( "Error while taking the screenshot." )
			);
			&fct_show_status_message( 1, $d->get("Error while taking the screenshot.") );
			&fct_control_main_window ('show');
			return FALSE;		
		}
		
		&fct_control_main_window('show', $present_after_active->get_active);
		
		return TRUE;
	}

	sub fct_upload {

		my $key = &fct_get_current_file;

		my @upload_array;

		#single file
		if ($key) {

			return FALSE unless &fct_screenshot_exists($key);
			push( @upload_array, $key );
			&dlg_upload(@upload_array);

			#update actions
			#new public links might be available
			&fct_update_actions(1, $key);

			#session tab
		} else {

			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						return FALSE unless &fct_screenshot_exists($key);
						push( @upload_array, $key );
					}

				},
				undef
			);
			&dlg_upload(@upload_array);
		}
		return TRUE;
	}

	sub fct_send {

		my $key = &fct_get_current_file;

		my @files_to_send;
		unless ($key) {
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						push( @files_to_send, $session_screens{$key}->{'long'} );
					}

				}
			);
		} else {
			push( @files_to_send, $session_screens{$key}->{'long'} );
		}
		
		my $sendto_string = undef;
		foreach my $sendto_filename ( @files_to_send ) {
			$sendto_string .= "'$sendto_filename' "
		}
		
		$shf->nautilus_sendto($sendto_string);
		
		return TRUE;
	}

	sub fct_email {

		my $key = &fct_get_current_file;

		my @files_to_email;
		unless ($key) {
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						push( @files_to_email, $session_screens{$key}->{'long'} );
					}

				}
			);
		} else {
			push( @files_to_email, $session_screens{$key}->{'uri'}->to_string );
		}
		
		#~ my $mail_string = undef;
		#~ foreach my $email_filename ( @files_to_email ) {
			#~ $mail_string .= "--attach '$email_filename' "
		#~ }
		#~ 
		#~ $shf->xdg_open_mail(undef, undef, $mail_string);

		#GConf
		my $client = Gnome2::GConf::Client->get_default;

		#global error handler function catch just the unchecked error
		$client->set_error_handling('handle-unreturned');
		$client->signal_connect(unreturned_error => sub {
			my ($client, $error) = @_;
			warn $error; # is a Glib::Error
		});
		
		#get mail client
		$client->get("/desktop/gnome/url-handlers/mailto/command") =~ /^(.*) /;
		my $mail_cmd = $1;
		if(defined $mail_cmd && $mail_cmd =~ /thunderbird/){
			#~ print $mail_cmd, "\n";
			$shf->thunderbird_open($mail_cmd, "-compose \"attachment='".join(",",@files_to_email)."'\"");
		}else{
			$shf->xdg_open(undef, "'mailto:?attach=".join("&attach=",@files_to_email )."'");		
		}
		
		return TRUE;
	}

	sub fct_print {

		my $key = &fct_get_current_file;

		my @pages;
		unless ($key) {
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						push( @pages, $session_screens{$key}->{'long'} );
					}

				}
			);
		} else {
			push( @pages, $session_screens{$key}->{'long'} );
		}

		my $op = Gtk2::PrintOperation->new;
		$op->set_job_name( SHUTTER_NAME . " - " . SHUTTER_VERSION . " - " . localtime );
		$op->set_n_pages( scalar @pages );
		$op->set_unit('pixel');
		$op->set_show_progress(TRUE);
		$op->set_default_page_setup($pagesetup);

		#restore settings if prossible
		if ( $shf->file_exists("$ENV{ HOME }/.shutter/printing.xml") ) {
			eval {
				my $ssettings = Gtk2::PrintSettings->new_from_file("$ENV{ HOME }/.shutter/printing.xml");
				$op->set_print_settings($ssettings);
			};
		}

		$op->signal_connect(
			'status-changed' => sub {
				my $op = shift;
				&fct_show_status_message( 1, $op->get_status_string );
			}
		);

		$op->signal_connect(
			'draw-page' => sub {
				my $op  = shift;
				my $pc  = shift;
				my $int = shift;

				#cairo context
				my $cr = $pc->get_cairo_context;

				#load pixbuf from file
				my $pixbuf = Gtk2::Gdk::Pixbuf->new_from_file( $pages[$int] );
				
				#~ my $pas = $pc->get_page_setup;
				#~ my $dpi_x = $pixbuf->get_width / $pas->get_page_width('inch');
				#~ my $dpi_y = $pixbuf->get_height / $pas->get_page_height('inch');
				
				#scale if image doesn't fit on page
				my $scale_x = $pc->get_width / $pixbuf->get_width;
				my $scale_y = $pc->get_height / $pixbuf->get_height;
				if(min($scale_x, $scale_y) < 1){
					$cr->scale(min($scale_x, $scale_y), min($scale_x, $scale_y));
				}
				
				Gtk2::Gdk::Cairo::Context::set_source_pixbuf( $cr, $pixbuf, 0, 0 );

				$cr->paint;

			}
		);

		$op->run( 'print-dialog', $window );

		#save settings
		my $settings = $op->get_print_settings;
		eval { $settings->to_file("$ENV{ HOME }/.shutter/printing.xml"); };

		return TRUE;
	}

	sub fct_open_with_program {
		my $dentry 		= shift;
		my $trans_name 	= shift;

		#no program set - exit
		return FALSE unless $dentry;

		#trans_name is optional here,
		#we use the name of the desktop entry if 
		#trans_name is not present
		my $name = $trans_name || $dentry->Name;

		my $key = &fct_get_current_file;

		my $exec_call;
		#single file
		if ($key) {

			return FALSE unless &fct_screenshot_exists($key);
			
			if($dentry =~ /shutter-built-in/){
				
				&fct_draw();

				&fct_show_status_message( 1, sprintf($d->get("%s opened with %s"), $session_screens{$key}->{'long'}, $d->get("Built-in Editor")) );
				
			}else{
				
				#everything is fine -> open it
				if ( $dentry->wants_uris ) {
					$exec_call = $dentry->parse_Exec( $session_screens{$key}->{'uri'}->to_string );
				} else {
					$exec_call = $dentry->parse_Exec( $session_screens{$key}->{'long'} );
				}

				&fct_show_status_message( 1, sprintf($d->get("%s opened with %s"), $session_screens{$key}->{'long'}, $name) );

			}		

			#session tab
		} else {

			my @open_files;

			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						my $key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
						if ( $dentry->wants_uris ) {
							push @open_files, $session_screens{$key}->{'uri'}->to_string;
						} else {
							push @open_files, $session_screens{$key}->{'long'};
						}
					}
				},
				undef
			);
			if ( @open_files > 0 ) {
				if ( $dentry->wants_list ) {
					$exec_call = $dentry->parse_Exec(@open_files);
				} else {
					foreach my $file (@open_files) {
						$exec_call .= $dentry->parse_Exec($file) . ";";
					}
				}
				&fct_show_status_message( 1, $d->get("Opened all files with") . " " . $name );
			}
		}

		if ($exec_call) {
			foreach ( split /;/, $exec_call ) {
				print Dumper $_ . " &" if $sc->get_debug;
				system( $_ . " &" );
			}
		}
		
		return TRUE;
	}

	sub fct_execute_plugin {
		my $arrayref = $_[1];
		my ( $plugin_value, $plugin_name, $plugin_lang, $key, $plugin_dialog, $plugin_progress ) = @$arrayref;

		unless ( $shf->file_exists( $session_screens{$key}->{'long'} ) ) {
			return FALSE;
		}

		#if it is a native perl plugin, use a plug to integrate it properly
		if ( $plugin_lang eq "perl" ) {		
			#hide plugin dialog
			$plugin_dialog->hide if defined $plugin_dialog;

			#dialog to show the plugin
			my $sdialog = Gtk2::Dialog->new( $plugin_name, $window, [qw/modal destroy-with-parent/] );
			$sdialog->set_resizable(FALSE);
			$sdialog->set_has_separator(FALSE); 
			# Ensure that the dialog box is destroyed when the user responds.
			$sdialog->signal_connect (response => sub { $_[0]->destroy });

			#initiate the socket to draw the contents of the plugin to our dialog
			my $socket = Gtk2::Socket->new;
			$sdialog->vbox->add($socket);
			$socket->signal_connect(
				'plug-removed' => sub {
					$sdialog->destroy();
					return TRUE;
				}
			);
			
			printf( "\n", $socket->get_id );
			
			my $pid = fork;
			if ( $pid < 0 ) {
				$sd->dlg_error_message( sprintf ( $d->get("Could not apply plugin %s"), "'" . $plugin_name . "'" ), $d->get("Failed") );
			}
			if ( $pid == 0 ) {		
				exec(
					sprintf(
						"$^X $plugin_value %d '$session_screens{$key}->{'long'}' $session_screens{$key}->{'width'} $session_screens{$key}->{'height'} $session_screens{$key}->{'filetype'}\n",
						$socket->get_id )
				);
			}
					
			$sdialog->show_all;
			$sdialog->run;

			waitpid($pid, 0);
				
			#check exit code
			if($? == 0){
				&fct_show_status_message( 1, sprintf ( $d->get("Successfully applied plugin %s"), "'" . $plugin_name . "'" ) );
			}elsif($? / 256 == 1 ){
				&fct_show_status_message( 1, sprintf ( $d->get("Could not apply plugin %s"), "'" . $plugin_name . "'" ) );
			}
			
			#...if not => simple execute the plugin via system (e.g. shell plugins)
		} else {

			print
				"$plugin_value $session_screens{$key}->{'long'} $session_screens{$key}->{'width'} $session_screens{$key}->{'height'} $session_screens{$key}->{'filetype'} submitted to plugin\n"
				if $sc->get_debug;

			#cancel handle, because file gets manipulated
			#multiple times
			if ( exists $session_screens{$key}->{'handle'} ) {
				$session_screens{$key}->{'handle'}->cancel;
			}
			
			#create a new process, so we are able to cancel the current operation
			my $plugin_process = Proc::Simple->new;

			$plugin_process->start(
				sub {
					system("'$plugin_value' '$session_screens{$key}->{'long'}' '$session_screens{$key}->{'width'}' '$session_screens{$key}->{'height'}' '$session_screens{$key}->{'filetype'}' ");				
					POSIX::_exit(0);
				}
			);
			
			#ignore delete-event during execute
			$plugin_dialog->signal_connect(
				'delete-event' => sub{
					return TRUE;		
				} 
			);

			#we are also able to show a little progress bar to give some feedback
			#to the user. there is no real progress because we are just executing a shell script
			while ( $plugin_process->poll ) {
				$plugin_progress->set_text($plugin_name." - ".$session_screens{$key}->{'short'});
				$plugin_progress->pulse;
				&fct_update_gui;
				usleep 100000;
			}

			&fct_update_gui;

			#finally show some status messages
			if ( $plugin_process->exit_status() == 0 ) {
				&fct_show_status_message( 1, sprintf ( $d->get("Successfully applied plugin %s"), "'" . $plugin_name . "'" ) );
			}else{
				$sd->dlg_error_message( 
					sprintf ( $d->get(  "Error while executing plugin %s." ), "'" . $plugin_name . "'" ) ,
					$d->get( "There was an error executing the plugin." ),
				);
			}
			
			#update session tab manually
			&fct_update_tab( $key, undef, $session_screens{$key}->{'uri'} );

			#setup a new filemonitor, so we get noticed if the file changed
			&fct_add_file_monitor($key);	

		}

		return TRUE;
	}

	sub fct_show_status_message {
		my $index = shift;
		my $status_text = shift;
		
		$status->pop($index);
		Glib::Source->remove ($session_start_screen{'first_page'}->{'statusbar_timer'}) if defined $session_start_screen{'first_page'}->{'statusbar_timer'};
		$status->push( $index, $status_text );

		#...and remove it
		$session_start_screen{'first_page'}->{'statusbar_timer'} = Glib::Timeout->add(
			3000,
			sub {
				$status->pop($index);
				#show file or session info again
				&fct_update_info_and_tray();
				return FALSE;
			}
		);
		
		return TRUE;
	}

	sub fct_update_info_and_tray {
		my $force_key = shift;
		
		my $key = undef;
		if($force_key){
			if($force_key eq "session"){
				$key = undef;
			}else{
				$key = $force_key;
			}			
		}else{
			$key = &fct_get_current_file;
		}
		
		#STATUSBAR AND WINDOW TITLE
		#--------------------------------------	
		#update statusbar when this image is current tab
		if($key && defined $session_screens{$key}->{'long'} && defined $session_screens{$key}->{'width'}){
			
			#change window title
			$window->set_title($session_screens{$key}->{'long'}." - ".SHUTTER_NAME);
			
			$status->push(1, $session_screens{$key}->{'width'} . 
							  " x " . 
							  $session_screens{$key}->{'height'} . 
							  " " . 
							  $d->get("pixels") .
							  "  " .
							  $shf->utf8_decode( Gnome2::VFS->format_file_size_for_display( $session_screens{$key}->{'size'} ) ) 
						   );

		#session tab
		}else{
			
			#change window title
			$window->set_title($d->get("Session")." - ".SHUTTER_NAME);
			
			$status->push(1, sprintf( $d->nget( "%s screenshot", "%s screenshots", scalar( keys(%session_screens) ) ) , scalar( keys(%session_screens) ) ) .
							  "  " .
							  $shf->utf8_decode( Gnome2::VFS->format_file_size_for_display(&fct_get_total_size_of_session) )
						   );
								
		}	

		#TRAY TOOLTIP
		#--------------------------------------	
		if ( $combobox_settings_profiles ) {
			if ( $tray && $tray->isa('Gtk2::StatusIcon') ) {
				if($combobox_settings_profiles->get_active_text){
					$tray->set_tooltip( $d->get("Current profile") . ": " . $combobox_settings_profiles->get_active_text );
				}else{
					$tray->set_tooltip(SHUTTER_NAME . " " . SHUTTER_VERSION);	
				}
			} elsif ( $tray && $tray->isa('Gtk2::TrayIcon') ) {
				$tooltips->set_tip( $tray, SHUTTER_NAME . " " . SHUTTER_VERSION );
			}
		}

		return TRUE;
	}

	sub fct_get_key_by_filename {
		my $filename = shift;
		
		return unless $filename;

		my $key = undef;
		#and loop through hash to find the corresponding key
		foreach ( keys %session_screens ) {
			next unless exists $session_screens{$_}->{'long'};
			#~ print "compare ".$session_screens{$_}->{'long'}." - $filename\n";
			if ( $session_screens{$_}->{'long'} eq $filename ) {
				$key = $_;
				last;
			}
		}
		
		return $key;
	}

	sub fct_get_key_by_pubfile {
		my $filename = shift;
		
		return unless $filename;

		my $key = undef;
		#and loop through hash to find the corresponding key
		foreach ( keys %session_screens ) {
			next unless exists $session_screens{$_}->{'links'};
			next unless exists $session_screens{$_}->{'links'}->{'ubuntu-one'};
			next unless exists $session_screens{$_}->{'links'}->{'ubuntu-one'}->{'pubfile'};
			#~ print "compare ".$session_screens{$_}->{'links'}->{'ubuntu-one'}->{'pubfile'}." - $filename\n";
			if ( $session_screens{$_}->{'links'}->{'ubuntu-one'}->{'pubfile'} eq $filename ) {
				$key = $_;
				last;
			}
		}
		
		return $key;
	}

	sub fct_get_file_by_index {
		my $index = shift;
		
		return unless $index;

		#get current page
		my $curr_page = $notebook->get_nth_page( $index );

		my $key = undef;
		#and loop through hash to find the corresponding key
		if($curr_page){
			foreach ( keys %session_screens ) {
				next unless exists $session_screens{$_}->{'tab_child'};
				if ( $session_screens{$_}->{'tab_child'} == $curr_page ) {
					$key = $_;
					last;
				}
			}
		}
		
		return $key;
	}

	sub fct_get_total_size_of_session {
		my $total_size = 0;
		foreach ( keys %session_screens ) {
			next unless $session_screens{$_}->{'size'};
			$total_size += $session_screens{$_}->{'size'};
		}
		return $total_size;		
	}

	sub fct_get_current_file {

		#get current page
		my $curr_page = $notebook->get_nth_page( $notebook->get_current_page );

		my $key = undef;
		#and loop through hash to find the corresponding key
		if($curr_page){
			foreach ( keys %session_screens ) {
				next unless ( exists $session_screens{$_}->{'tab_child'} );
				if ( $session_screens{$_}->{'tab_child'} == $curr_page ) {
					$key = $_;
					last;
				}
			}
		}
		
		return $key;
	}

	sub fct_update_profile_selectors {
		my ($combobox_settings_profiles, $current_profiles_ref, $recur_widget) = @_;

		#populate quick selector as well
		if(scalar @{$current_profiles_ref} > 0){
			#tray menu
			foreach($tray_menu->get_children){
				if ($_->get_name eq 'quicks'){
					$_->set_submenu( fct_ret_profile_menu( $combobox_settings_profiles, $current_profiles_ref ) );					
					$_->set_sensitive(TRUE);
					last;
				}	
			}
					
			#main menu
			$sm->{_menuitem_quicks}->set_submenu( fct_ret_profile_menu( $combobox_settings_profiles, $current_profiles_ref ) );
			$sm->{_menuitem_quicks}->set_sensitive(TRUE);

			#and statusbar
			#FIXME - some explanation is missing here
			unless($recur_widget && $recur_widget eq $combobox_status_profiles){
				if(defined $combobox_status_profiles && defined $combobox_status_profiles_label){
					$combobox_status_profiles_label->destroy;
					$combobox_status_profiles->destroy;
				}
				
				$combobox_status_profiles_label = Gtk2::Label->new( $d->get("Profile") . ":" );
				$combobox_status_profiles = Gtk2::ComboBox->new_text;
				$status->pack_end( Gtk2::HSeparator->new , FALSE, FALSE, 6 );
				$status->pack_end( $combobox_status_profiles, FALSE, FALSE, 0 );
				$status->pack_end( $combobox_status_profiles_label, FALSE, FALSE, 0 );
				
				foreach my $profile ( @{$current_profiles_ref} ) {
					$combobox_status_profiles->append_text($profile);	
				}			
		
				$combobox_status_profiles->set_active($combobox_settings_profiles->get_active);
				
				$combobox_status_profiles->signal_connect(
					'changed' => sub {
						my $widget = shift;
					
						$combobox_settings_profiles->set_active($widget->get_active);
						&evt_apply_profile( $widget, $combobox_settings_profiles, $current_profiles_ref );
		
					}
				);
				
				$status->show_all;
			}

		}else{
			#tray menu
			foreach($tray_menu->get_children){
				if ($_->get_name eq 'quicks'){
					$_->remove_submenu;
					$_->set_sensitive(FALSE);
					last;
				}	
			}		
			#main menu
			$sm->{_menuitem_quicks}->remove_submenu;
			$sm->{_menuitem_quicks}->set_sensitive(FALSE);
			
			#and statusbar
			if(defined $combobox_status_profiles && defined $combobox_status_profiles_label){
				$combobox_status_profiles_label->destroy;
				$combobox_status_profiles->destroy;
			}
		}	
		return TRUE;
	}

	sub fct_update_tab {

		#mandatory
		my $key = shift;
		return FALSE unless $key;

		#optional, e.g.used by fct_integrate...
		my $pixbuf 			= shift;
		my $uri    			= shift;
		my $force_thumb		= shift;
		my $xdo				= shift;

		$session_screens{$key}->{'uri'}      = $uri if $uri;
		$session_screens{$key}->{'mtime'} 	 = -1 unless $session_screens{$key}->{'mtime'};

		#something wrong here
		unless(defined $session_screens{$key}->{'uri'}){
			return FALSE;	
		}

		#sometimes there are some read errors
		#because the CHANGED signal gets emitted by the file monitor
		#but the file is still in use (e.g. plugin, external app)
		#we try to read the fileinfos and the file itsels several times
		#until throwing an error
		my $error_counter = 0;
		while($error_counter <= MAX_ERROR){

			my $fileinfo  = $session_screens{$key}->{'uri'}->get_file_info('default');

			#does the file exist?
			if($session_screens{$key}->{'uri'}->exists){
				
				#maybe we need no update
				if ($fileinfo->{'mtime'} == $session_screens{$key}->{'mtime'} && !$uri ){
					print "Updating fileinfos REJECTED for key: $key (not modified)\n" if $sc->get_debug;			
					return TRUE;
				}
				
				print "Updating fileinfos for key: $key\n" if $sc->get_debug;

				#FILEINFO
				#--------------------------------------
				$session_screens{$key}->{'mtime'}    = $fileinfo->{'mtime'};
				$session_screens{$key}->{'size'}     = $fileinfo->{'size'};

				$session_screens{$key}->{'short'}    = $shf->utf8_decode(
														Gnome2::VFS->unescape_string(
															$session_screens{$key}->{'uri'}->extract_short_name
															)
														);
				$session_screens{$key}->{'long'}     = $shf->utf8_decode(
														Gnome2::VFS->unescape_string(
															$session_screens{$key}->{'uri'}->get_path
															)
														);
				$session_screens{$key}->{'folder'}   = $shf->utf8_decode(
														Gnome2::VFS->unescape_string(
															$session_screens{$key}->{'uri'}->extract_dirname
															)
														);
				$session_screens{$key}->{'filetype'} = $session_screens{$key}->{'short'};
				$session_screens{$key}->{'filetype'} =~ s/.*\.//ig;

				#just the name
				$session_screens{$key}->{'name'} = $session_screens{$key}->{'short'};
				$session_screens{$key}->{'name'} =~ s/\.$session_screens{$key}->{'filetype'}//g;

				#mime type
				$session_screens{$key}->{'mime_type'} = Gnome2::VFS->get_mime_type_for_name( $session_screens{$key}->{'uri'}->to_string );

				#THUMBNAIL
				#--------------------------------------
				#maybe we have a pixbuf already (e.g. after taking a screenshot)
				unless ($pixbuf) {
					eval {
						$pixbuf = Gtk2::Gdk::Pixbuf->new_from_file( $session_screens{$key}->{'long'} );		
					};
					if ($@) {
						#increment error counter 
						#and go to next try
						$error_counter++;
						sleep 1;
						#we need to reset the modification time
						#because the change would not be 
						#recognized otherwise
						$session_screens{$key}->{'mtime'} = -1;
						next;
					}
				}
				
				#setting pixbuf
				$session_screens{$key}->{'image'}->set_pixbuf( $pixbuf );
				
				#UPDATE INFOS
				#--------------------------------------

				#get dimensions - using the pixbuf
				$session_screens{$key}->{'width'}  = $pixbuf->get_width;
				$session_screens{$key}->{'height'} = $pixbuf->get_height;

				#generate thumbnail if file is not too large
				#set flag
				if(	$session_screens{$key}->{'width'} <= 10000 && $session_screens{$key}->{'height'} <= 10000 ){					
					$session_screens{$key}->{'no_thumbnail'} = FALSE;
				}else{
					$session_screens{$key}->{'no_thumbnail'} = TRUE;	
				}

				#create tempfile
				#maybe we have to restore the file later
				my ( $tmpfh, $tmpfilename ) = tempfile(UNLINK => 1);

				#UNDO / REDO
				#--------------------------------------
				
				#blocked (e.g. renaming)
				if(defined $xdo && $xdo eq 'block'){
					
					unlink $tmpfilename;
				
				#clear (e.g. save_as)
				}elsif(defined $xdo && $xdo eq 'clear'){

					while (defined $session_screens{$key}->{'undo'} && scalar @{ $session_screens{$key}->{'undo'} } > 0){
						unlink shift @{ $session_screens{$key}->{'undo'} };	
					}	
					while (defined $session_screens{$key}->{'redo'} && scalar @{ $session_screens{$key}->{'redo'} } > 0){
						unlink shift @{ $session_screens{$key}->{'redo'} };	
					}	

					push @{$session_screens{$key}->{'undo'}}, $tmpfilename;				
					cp($session_screens{$key}->{'long'}, $tmpfilename);
				
				#push to undo	
				}else{
					
					#clear redo unless triggered from gui (undo/redo buttons)
					if(!defined $xdo){
						while (defined $session_screens{$key}->{'redo'} && scalar @{ $session_screens{$key}->{'redo'} } > 0){
							unlink shift @{ $session_screens{$key}->{'redo'} };	
						}
					}
					
					push @{$session_screens{$key}->{'undo'}}, $tmpfilename;				
					cp($session_screens{$key}->{'long'}, $tmpfilename);				
				
				}
				
				#thumbnail in tab
				my $thumb;
				unless($session_screens{$key}->{'no_thumbnail'}){
					#update tab icon
					$thumb = $sthumb->get_thumbnail(
						$session_screens{$key}->{'uri'}->to_string,
						$session_screens{$key}->{'mime_type'},
						$session_screens{$key}->{'mtime'},
						0.2,
						$force_thumb
					);
					$session_screens{$key}->{'tab_icon'}->set_from_pixbuf( $thumb );
				}

				#UPDATE FIRST TAB - VIEW
				#--------------------------------------				

				my $thumb_view;
				unless($session_screens{$key}->{'no_thumbnail'}){
					#update view icon
					$thumb_view = $sthumb->get_thumbnail(
						$session_screens{$key}->{'uri'}->to_string,
						$session_screens{$key}->{'mime_type'},
						$session_screens{$key}->{'mtime'},
						0.5
					);
					#update dnd pixbuf
					$session_screens{$key}->{'image'}->drag_source_set_icon_pixbuf($thumb_view);	
				}else{
					$thumb_view = Gtk2::Gdk::Pixbuf->new ('rgb', TRUE, 8, 5, 5);	
					$thumb_view->fill(0x00000000);	
				}

				unless(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
					$session_screens{$key}->{'iter'} = $session_start_screen{'first_page'}->{'model'}->append;
					$session_start_screen{'first_page'}->{'model'}->set( $session_screens{$key}->{'iter'}, 0, $thumb_view, 1, $session_screens{$key}->{'short'}, 2, $key );
				}else{
					$session_start_screen{'first_page'}->{'model'}->set( $session_screens{$key}->{'iter'}, 0, $thumb_view, 1, $session_screens{$key}->{'short'}, 2, $key );					
				}
							
				#update first tab
				&fct_update_info_and_tray();

				#update menu actions
				my $current_key = &fct_get_current_file;
				if(defined $current_key && $current_key eq $key){		
					&fct_update_actions(1, $key);
				}

				return TRUE;
							
			#file does not exist
			}else{

				#mark file as deleted
				$session_screens{$key}->{'deleted'} = TRUE;	

				#we only handle one case here:
				#file was deleted in filesystem and we got informed about that...	
				my $response = $sd->dlg_question_message(
					$d->get("Try to resave the file?"),
					sprintf( $d->get("Image %s was not found on disk"), "'" . $session_screens{$key}->{'long'} . "'" ),
					'gtk-discard', 'gtk-save'
				);
				
				#handle different responses
				if($response == 10){

					$notebook->remove_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );    #delete tab
					&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("removed from session") )
						if defined( $session_screens{$key}->{'long'} );

					if(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
						$session_start_screen{'first_page'}->{'model'}->remove( $session_screens{$key}->{'iter'} );
					}

					delete( $session_screens{$key} );    
					
				}elsif($response == 20){
					
					#try to resave the file
					#(current version is always the last element in the array)
					my $current_version = pop @{$session_screens{$key}->{'undo'}};
					
					my $pixbuf;
					eval{
						$pixbuf = Gtk2::Gdk::Pixbuf->new_from_file( $current_version );
					};
					#restoring the last version failed => delete the screenshot	
					if($@){

						$sd->dlg_error_message( 
							sprintf( $d->get("Error while saving the image %s."), "'" . $session_screens{$key}->{'short'} . "'"),
							sprintf( $d->get("There was an error saving the image to %s."), "'" . $session_screens{$key}->{'folder'} . "'"),		
							undef, undef, undef,
							undef, undef, undef,
							$@
						);

						$notebook->remove_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );    #delete tab
						&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("removed from session") )
							if defined( $session_screens{$key}->{'long'} );

						if(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
							$session_start_screen{'first_page'}->{'model'}->remove( $session_screens{$key}->{'iter'} );
						}

						delete( $session_screens{$key} );   

						&fct_update_info_and_tray();
						return FALSE;
						
					}
						
					if($sp->save_pixbuf_to_file($pixbuf, $session_screens{$key}->{'long'}, $session_screens{$key}->{'filetype'})){

						#setup a new filemonitor, so we get noticed if the file changed
						&fct_add_file_monitor($key);

						&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("saved"));
					
						&fct_update_info_and_tray();
						return TRUE;
					
					#resave failed => delete the screenshot	
					}else{

						$notebook->remove_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );    #delete tab
						&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("removed from session") )
							if defined( $session_screens{$key}->{'long'} );

						if(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
							$session_start_screen{'first_page'}->{'model'}->remove( $session_screens{$key}->{'iter'} );
						}

						delete( $session_screens{$key} );    				

					}	
				}
				
				&fct_update_info_and_tray();
				return FALSE;

			}	 
					
		}#end while($error_counter <= MAX_ERROR){

		#could not load the file => show an error message
		my $response = $sd->dlg_error_message( 
			sprintf ( $d->get(  "Error while opening image %s." ), "'" . $session_screens{$key}->{'long'} . "'" ) ,
			$d->get( "There was an error opening the image." ),
			undef, undef, undef,
			undef, undef, undef,
			$@
		);	

		$notebook->remove_page( $notebook->page_num( $session_screens{$key}->{'tab_child'} ) );    #delete tab
		&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("removed from session") )
			if defined( $session_screens{$key}->{'long'} );

		if(defined $session_screens{$key}->{'iter'} && $session_start_screen{'first_page'}->{'model'}->iter_is_valid($session_screens{$key}->{'iter'})){
			$session_start_screen{'first_page'}->{'model'}->remove( $session_screens{$key}->{'iter'} );
		}

		delete( $session_screens{$key} );    
		
		&fct_update_info_and_tray();
		return FALSE;

	}

	sub fct_get_latest_tab_key {
		my $max_key = 0;
		foreach my $key ( keys %session_screens ) {
			$key =~ /\[(.*)\]/;
			$max_key = $1 if ( $1 > $max_key );
		}
		return $max_key + 1;
	}

	sub fct_imagemagick_perform {
		my ( $function, $file, $data ) = @_;
		
		my $pixbuf  = undef;
		my $result 	= undef;
		$file = $shf->switch_home_in_file($file);
		
		if ( $function eq "reduce_colors" ) {
			$result = `convert '$file' -colors $data '$file'`;
			$pixbuf = Gtk2::Gdk::Pixbuf->new_from_file( $file );
		} 
		
		return $pixbuf;
	}

	sub fct_check_installed_programs {

		#update list of available programs in settings dialog as well
		if ($progname) {

			my $model         = $progname->get_model();
			my $progname_iter = $progname->get_active_iter();

			#get last prog
			my $progname_value;
			if ( defined $progname_iter ) {
				$progname_value = $model->get_value( $progname_iter, 1 );
			}

			#rebuild model with new hash of installed programs...
			$model = &fct_get_program_model;
			$progname->set_model($model);

			#...and try to set last	value
			if ($progname_value) {
				$model->foreach( \&fct_iter_programs, $progname_value );
			} else {
				$progname->set_active(0);
			}

			#nothing has been set
			if ( $progname->get_active == -1 ) {
				$progname->set_active(0);
			}
		}

		return TRUE;
	}

	sub fct_get_next_filename {
		my ( $filename_value, $folder, $filetype_value ) = @_;

		$filename_value =~ s/\\//g;
		
		#random number - should be earlier than %N reading, as $R is actually a part of date
		if ( $filename_value =~ /\$R{1,}/ ) {
			#how many Rs are used? (important for formatting)
			my $pos_proc 	= index( $filename_value, "\$R", 0 );
			my $r_counter 	= 0;
			my $last_pos 	= $pos_proc;
			$pos_proc++;

			while ( $pos_proc <= length($filename_value) ) {
				$last_pos = index( $filename_value, "R", $pos_proc );
				if ( $last_pos != -1 && ($last_pos - $pos_proc <= 1)) {
					$r_counter++;
					$pos_proc++;
				} else {
					last;
				}
			}
			
			#prepare filename
			print "---$r_counter Rs used in wild-card\n" if $sc->get_debug;
			my $marks = "";
			my $i     = 0;
			
			# Md5 will contain a salt (shutter) and a seconds since 1970
			my $md5_data = "shutter".time;
			my $md5_hash = md5_hex( $md5_data );
			
			# TODO: set random offset? I guess, current implementation is sufficient
			$marks = substr($md5_hash,0,$r_counter);
			
			#switch $Rs to a part of the hash
			$filename_value =~ s/\$R{1,}/$marks/g;
		}

		#auto increment
		if ( $filename_value =~ /\%N{1,}/ ) {

			#how many Ns are used? (important for formatting)
			my $pos_proc 	= index( $filename_value, "%", 0 );
			my $n_counter 	= 0;
			my $last_pos 	= $pos_proc;
			$pos_proc++;

			while ( $pos_proc <= length($filename_value) ) {
				$last_pos = index( $filename_value, "N", $pos_proc );
				if ( $last_pos != -1 && ($last_pos - $pos_proc <= 1)) {
					$n_counter++;
					$pos_proc++;
				} else {
					last;
				}
			}

			#prepare filename
			print "$n_counter Ns used in wild-card\n" if $sc->get_debug;
			my $marks = "";
			my $i     = 0;

			while ( $i < $n_counter ) {
				$marks .= '\d';
				$i++;
			}

			#switch %Ns to \d
			$filename_value =~ s/\%N{1,}/$marks/g;

			#construct regex
			my $first = index( "$filename_value", '\d', 0 );
			my $search_file_start 	= quotemeta substr( $filename_value, 0, $first );
			my $search_file_end 	= quotemeta substr( $filename_value, $first+$n_counter*2, length($filename_value)-$first+$n_counter*2 );
			
			#store regex to string
			my $search_pattern = qr/$search_file_start($marks)$search_file_end\.$filetype_value/;

			print "Searching for files with pattern: $search_pattern\n"
				if $sc->get_debug;
			
			#shutter's custom wildcards are switched to reg.expressions in this search
			#($w, $h, $name)
			$search_pattern =~ s/\\\$w/\\d{1,}/g;
			$search_pattern =~ s/\\\$h/\\d{1,}/g;
			$search_pattern =~ s/\\\$profile/.{1,}/g;
			$search_pattern =~ s/\\\$name/.{1,}/g;

			print "Searching for files with pattern: $search_pattern\n"
				if $sc->get_debug;

			#get_all files from directory
			#we handle the listing with GnomeVFS to read remote dirs as well
			my ( $result, $uri_list ) = Gnome2::VFS::Directory->open( $folder, 'default' );

			#could not open directory, show error message and return
			unless ($result eq 'ok'){
				
				my $response = $sd->dlg_error_message( 
					sprintf( $d->get( "Error while opening directory %s."), "'" . $folder. "'" ),
					$d->get( "There was an error determining the filename." ),
					undef, undef, undef,
					undef, undef, undef,
					Gnome2::VFS->result_to_string ($result)
				);

				return FALSE;

			}

			#reading all files in current directory
			my $next_count = 0;
			while ( my ( $result, $file ) = $uri_list->read_next ) {
				if ( $result eq 'ok' ) {				
					my $fileinfo	= Gnome2::VFS::FileInfo->new($file);
					my $fname		= $shf->utf8_decode($fileinfo->{'name'});
					
					#not a regular file? -> skip
					next unless $fileinfo->{'type'} eq 'regular';
					
					#does the current file match the pattern?
					print "Comparing $fname\n" if $sc->get_debug;
					if ($fname =~ $search_pattern){
						my $curr_value = $1;
						if($curr_value && $curr_value > $next_count){
							$next_count = $curr_value;
							print "$next_count is currently greatest value...\n"
								if $sc->get_debug;						
						}
					}
				} elsif ( $result eq 'error-eof' ) {
					$uri_list->close();
					last;
				} else {
					next;
				}
			}

			$next_count = 0 unless $next_count =~ /^(\d+\.?\d*|\.\d+)$/;
			unless(length($next_count + 1) > $n_counter){
				$next_count = sprintf( "%0" . $n_counter . "d", $next_count + 1 );
			}else{
				$next_count = sprintf( "%0" . $n_counter . "d", $next_count);
			}
			$marks = quotemeta $marks;
			
			#switch placeholder to $next_count
			$filename_value =~ s/$marks/$next_count/g;

		}

		#create new uri
		my $new_uri = Gnome2::VFS::URI->new("$folder/$filename_value.$filetype_value");
		if ( $new_uri->exists ) {
			my $count             = 1;
			my $existing_filename = $filename_value;
			while ( $new_uri->exists ) {
				$filename_value = $existing_filename . "(" . sprintf( "%03d", $count++ ) . ")";
				$new_uri 	= Gnome2::VFS::URI->new($folder);
				$new_uri    = $new_uri->append_string("$filename_value.$filetype_value");
				print "Checking new uri: " . $new_uri->to_string . "\n" if $sc->get_debug;
			}
		}

		return $new_uri;
	}

	sub fct_check_installed_plugins {

		my $plugin_dialog = Gtk2::MessageDialog->new( $window, [qw/modal destroy-with-parent/], 'info', 'close', $d->get("Updating plugin information") );
		$plugin_dialog->{destroyed} = FALSE;

		$plugin_dialog->set_title("Shutter");
		
		$plugin_dialog->set( 'secondary-text' => $d->get("Please wait while Shutter updates the plugin information") . "." );

		$plugin_dialog->signal_connect( response => sub { $plugin_dialog->{destroyed} = TRUE; $_[0]->destroy; } );
		
		$plugin_dialog->set_resizable(TRUE);

		my $plugin_progress = Gtk2::ProgressBar->new;
		$plugin_progress->set_no_show_all(TRUE);
		$plugin_progress->set_ellipsize('middle');
		$plugin_progress->set_orientation('left-to-right');
		$plugin_progress->set_fraction(0);

		$plugin_dialog->vbox->add($plugin_progress);
		
		my @plugin_paths = ( "$shutter_root/share/shutter/resources/system/plugins/*/*", "$ENV{'HOME'}/.shutter/plugins/*/*" );

		#fallback icon
		# maybe the plugin 
		# does not provide a custom icon
		my $fb_pixbuf_path 	= "$shutter_root/share/shutter/resources/icons/executable.svg";
		my $fb_pixbuf		= Gtk2::Gdk::Pixbuf->new_from_file_at_size( $fb_pixbuf_path, Gtk2::IconSize->lookup('menu') );

		foreach my $plugin_path (@plugin_paths) {
			my @plugins = glob($plugin_path);
			foreach (@plugins) {
				if ( -d $_ ) {
					my $dir_name = $_;

					#parse filename
					my ( $name, $folder, $type ) = fileparse( $dir_name, qr/\.[^.]*/ );
					
					#file exists
					if ( $shf->file_exists("$dir_name/$name") ) {

						#file is executable
						if ( $shf->file_executable("$dir_name/$name") ) {

							#new plugin information?
							unless ( $plugins{$_}->{'binary'}
								&& $plugins{$_}->{'name'}
								&& $plugins{$_}->{'category'}
								&& $plugins{$_}->{'tooltip'}
								&& $plugins{$_}->{'lang'} )
							{
															
								#show dialog and progress bar
								if(!$plugin_dialog->window && !$plugin_dialog->{destroyed}){
									$plugin_progress->show;
									$plugin_dialog->show_all;
								}

								print "\nINFO: new plugin information detected - $dir_name/$name\n";

								#path to executable
								$plugins{$_}->{'binary'} = "$dir_name/$name";

								#name
								$plugins{$_}->{'name'} = &fct_plugin_get_info( $plugins{$_}->{'binary'}, 'name' );

								#category
								$plugins{$_}->{'category'} = &fct_plugin_get_info( $plugins{$_}->{'binary'}, 'sort' );

								#tooltip
								$plugins{$_}->{'tooltip'} = &fct_plugin_get_info( $plugins{$_}->{'binary'}, 'tip' );

								#language (shell, perl etc.)
								#=> directory name
								my $folder_name = dirname($dir_name);
								$folder_name =~ /.*\/(.*)/;
								$plugins{$_}->{'lang'} = $1;

								#refresh the progressbar
								$plugin_progress->pulse;
								$plugin_progress->set_text($plugins{$_}->{'binary'});

								#refresh gui
								&fct_update_gui;

							}

							$plugins{$_}->{'lang'} = "shell"
								if $plugins{$_}->{'lang'} eq "";

							chomp( $plugins{$_}->{'name'} );
							chomp( $plugins{$_}->{'category'} );
							chomp( $plugins{$_}->{'tooltip'} );
							chomp( $plugins{$_}->{'lang'} );

							#pixbuf
							$plugins{$_}->{'pixbuf'} = $plugins{$_}->{'binary'} . ".png"
								if ( $shf->file_exists( $plugins{$_}->{'binary'} . ".png" ) );
							$plugins{$_}->{'pixbuf'} = $plugins{$_}->{'binary'} . ".svg"
								if ( $shf->file_exists( $plugins{$_}->{'binary'} . ".svg" ) );

							if ( $shf->file_exists( $plugins{$_}->{'pixbuf'} ) ) {
								$plugins{$_}->{'pixbuf_object'}
									= Gtk2::Gdk::Pixbuf->new_from_file_at_size( $plugins{$_}->{'pixbuf'}, Gtk2::IconSize->lookup('menu') );
							} else {
								$plugins{$_}->{'pixbuf'} 		= $fb_pixbuf_path;
								$plugins{$_}->{'pixbuf_object'} = $fb_pixbuf;
							}
							if ( $sc->get_debug ) {
								print "$plugins{$_}->{'name'} - $plugins{$_}->{'binary'}\n";
							}
							
						}else{
							my $changed = chmod(0755, "$dir_name/$name");
							unless($changed){
								print "\nERROR: plugin exists but is not executable - $dir_name/$name\n";
								delete $plugins{$_};
							}
						} #endif plugin is executable
						
					} else {
						delete $plugins{$_};
					}    #endif plugin exists
				
				}
			}
		}

		#destroys the plugin dialog
		$plugin_dialog->response('ok');

		return TRUE;
	}

	sub fct_plugin_get_info {
		my ( $plugin, $info ) = @_;

		my $plugin_info = `$plugin $info`;
		utf8::decode $plugin_info;
		
		return $plugin_info;
	}

	sub fct_iter_programs {
		my ( $model, $path, $iter, $search_for ) = @_;
		my $progname_value = $model->get_value( $iter, 1 );
		return FALSE if $search_for ne $progname_value;
		$progname->set_active_iter($iter);
		return TRUE;
	}

	sub fct_ret_workspace_menu {
		my $init = shift;

		my $menu_wrksp = Gtk2::Menu->new;

		my $screen = Gnome2::Wnck::Screen->get_default;
		#~ $screen->force_update();

		#we determine the wm name but on older
		#version of libwnck (or the bindings)
		#the needed method is not available
		#in this case we use gdk to do it
		#
		#this leads to a known problem when switching
		#the wm => wm_name will still remain the old one
		my $wm_name = Gtk2::Gdk::Screen->get_default->get_window_manager_name;
		if($screen->can('get_window_manager_name')){
			$wm_name = $screen->get_window_manager_name;
		}

		my $active_workspace = $screen->get_active_workspace;
		
		#we need to handle different window managers here because there are some different models related
		#to workspaces and viewports
		#	compiz uses "multiple workspaces" - "multiple viewports" model for example
		#	default gnome wm metacity simply uses multiple workspaces
		#we will try to handle them by name
		my @workspaces = ();
		for ( my $wcount = 0; $wcount < $screen->get_workspace_count; $wcount++ ) {
			push( @workspaces, $screen->get_workspace($wcount) );
		}

		foreach my $space (@workspaces) {
			next unless defined $space;
			
			#compiz
			if ( $wm_name =~ /compiz/ ){

				#calculate viewports with size of workspace
				my $vpx = $space->get_viewport_x;
				my $vpy = $space->get_viewport_y;

				my $n_viewports_column = int( $space->get_width / $screen->get_width );
				my $n_viewports_rows   = int( $space->get_height / $screen->get_height );

				#rows
				for ( my $j = 0; $j < $n_viewports_rows; $j++ ) {

					#columns
					for ( my $i = 0; $i < $n_viewports_column; $i++ ) {
						my @vp = ( $i * $screen->get_width, $j * $screen->get_height );
						my $vp_name = "$wm_name x: $i y: $j";

						print "shutter_wrksp_direct_compiz" . $vp[0] . "x" . $vp[1] . "\n"
							if $sc->get_debug;

						my $vp_item = Gtk2::MenuItem->new_with_label( ucfirst $vp_name );
						$vp_item->signal_connect(
							'activate' => \&evt_take_screenshot,
							"shutter_wrksp_direct_compiz" . $vp[0] . "x" . $vp[1]
						);
						$menu_wrksp->append($vp_item);

						#do not offer current viewport
						if ( $vp[0] == $vpx && $vp[1] == $vpy ) {
							$vp_item->set_sensitive(FALSE);
						}
					}    #columns
				}    #rows

			#all other wm manager like metacity etc.
			#we could add more of them here if needed			
			}else{
				
				my $wrkspace_item = Gtk2::MenuItem->new_with_label( $space->get_name );
				$wrkspace_item->signal_connect(
					'activate' => \&evt_take_screenshot,
					"shutter_wrksp_direct" . $space->get_number
				);
				$menu_wrksp->append($wrkspace_item);
			
				if ($active_workspace && $active_workspace->get_number == $space->get_number ) {
					$wrkspace_item->set_sensitive(FALSE);
				}
			
			}
		} 

		#entry for capturing all workspaces
		$menu_wrksp->append( Gtk2::SeparatorMenuItem->new );
		
		my $allwspaces_item = Gtk2::MenuItem->new_with_label( $d->get("Capture All Workspaces"));
		$allwspaces_item->signal_connect(
			'activate' => \&evt_take_screenshot,
			"shutter_wrksp_direct" . 'all'
		);
		$menu_wrksp->append($allwspaces_item);

		$menu_wrksp->append( Gtk2::SeparatorMenuItem->new );

		#monitor flag
		my $n_mons = Gtk2::Gdk::Screen->get_default->get_n_monitors;

		#use only current monitore
		$menu_wrksp->append( Gtk2::SeparatorMenuItem->new );
		if ($init) {
			$current_monitor_active = Gtk2::CheckMenuItem->new_with_label( $d->get("Limit to current monitor") );
			if ( defined $settings_xml->{'general'}->{'current_monitor_active'} ) {
				$current_monitor_active->set_active( $settings_xml->{'general'}->{'current_monitor_active'} );
			} else {
				$current_monitor_active->set_active(FALSE);
			}
			$menu_wrksp->append($current_monitor_active);
		} else {
			$current_monitor_active->reparent($menu_wrksp);
		}

		$tooltips->set_tip(
			$current_monitor_active,
			sprintf(
				$d->nget(
					"This option is only useful when you are running a multi-monitor system (%d monitor detected).\nEnable it to capture only the current monitor.",
					"This option is only useful when you are running a multi-monitor system (%d monitors detected).\nEnable it to capture only the current monitor.",
					$n_mons
				),
				$n_mons
			)
		);
		if ( $n_mons > 1 ) {
			$current_monitor_active->set_sensitive(TRUE);
		} else {
			$current_monitor_active->set_active(FALSE);
			$current_monitor_active->set_sensitive(FALSE);
		}

		$menu_wrksp->show_all();
		return $menu_wrksp;
	}

	sub fct_ret_window_menu {
		my $screen = Gnome2::Wnck::Screen->get_default;
		#~ $screen->force_update();

		my $active_workspace = $screen->get_active_workspace;

		my $menu_windows = Gtk2::Menu->new;
		foreach my $win ( $screen->get_windows_stacked ) {
			if ($active_workspace && $win->is_visible_on_workspace( $active_workspace ) ) {
				my $window_item = Gtk2::ImageMenuItem->new_with_label( $win->get_name );
				$window_item->set_image( Gtk2::Image->new_from_pixbuf( $win->get_mini_icon ) );
				$window_item->set('always_show_image' => TRUE) if Gtk2->CHECK_VERSION( 2, 16, 0 );
				$window_item->signal_connect(
					'activate' => \&evt_take_screenshot,
					"shutter_window_direct" . $win->get_xid
				);
				$menu_windows->append($window_item);
			}
		}

		$menu_windows->show_all;
		return $menu_windows;
	}

	sub fct_ret_tray_menu {
		
		my $traytheme = $sc->get_theme;

		my $menu_tray = Gtk2::Menu->new();
		
		#selection
		my $menuitem_select = Gtk2::ImageMenuItem->new_with_mnemonic( $d->get('_Selection') );
		eval{
			my $ccursor_pb = Gtk2::Gdk::Cursor->new('crosshair')->get_image->scale_simple(Gtk2::IconSize->lookup('menu'), 'bilinear');
			$menuitem_select->set_image( 
				Gtk2::Image->new_from_pixbuf($ccursor_pb)
			);	
		};
		if($@){		
			if($traytheme->has_icon('applications-accessories')){
				$menuitem_select->set_image(
					Gtk2::Image->new_from_icon_name( 'applications-accessories', 'menu' )	
				);
			}else{
				$menuitem_select->set_image(
					Gtk2::Image->new_from_pixbuf(
						Gtk2::Gdk::Pixbuf->new_from_file_at_size( "$shutter_root/share/shutter/resources/icons/selection.svg", Gtk2::IconSize->lookup('menu') )
					)
				);
			}
		}
		$menuitem_select->signal_connect(
			activate => \&evt_take_screenshot,
			'tray_select'
		);
		
		#full screen
		my $menuitem_raw = Gtk2::ImageMenuItem->new_from_stock( 'gtk-fullscreen' );
		$menuitem_raw->signal_connect(
			activate => \&evt_take_screenshot,
			'tray_raw'
		);
		
		#window
		my $menuitem_window = Gtk2::ImageMenuItem->new_with_mnemonic( $d->get('W_indow') );
		if($traytheme->has_icon('gnome-window-manager')){
			$menuitem_window->set_image( Gtk2::Image->new_from_icon_name( 'gnome-window-manager', 'menu' ) );	
		}else{
			$menuitem_window->set_image(
				Gtk2::Image->new_from_pixbuf(
					Gtk2::Gdk::Pixbuf->new_from_file_at_size( "$shutter_root/share/shutter/resources/icons/sel_window.svg", Gtk2::IconSize->lookup('menu') )
				)
			);
		}
		$menuitem_window->signal_connect(
			activate => \&evt_take_screenshot,
			'tray_window'
		);
		
		#section
		my $menuitem_window_sect = Gtk2::ImageMenuItem->new_with_mnemonic( $d->get('Se_ction') );
		if($traytheme->has_icon('gdm-xnest')){
			$menuitem_window_sect->set_image( Gtk2::Image->new_from_icon_name( 'gdm-xnest', 'menu' ) );	
		}else{
			$menuitem_window_sect->set_image(
				Gtk2::Image->new_from_pixbuf(
					Gtk2::Gdk::Pixbuf->new_from_file_at_size(
						"$shutter_root/share/shutter/resources/icons/sel_window_section.svg",
						Gtk2::IconSize->lookup('menu')
					)
				)
			);
		}
		$menuitem_window_sect->signal_connect(
			activate => \&evt_take_screenshot,
			'tray_section'
		);

		#menu
		my $menuitem_window_menu = Gtk2::ImageMenuItem->new_with_mnemonic( $d->get('_Menu') );
		if($traytheme->has_icon('alacarte')){
			$menuitem_window_menu->set_image( Gtk2::Image->new_from_icon_name( 'alacarte', 'menu' ) );	
		}else{
			$menuitem_window_menu->set_image(
				Gtk2::Image->new_from_pixbuf(
					Gtk2::Gdk::Pixbuf->new_from_file_at_size(
						"$shutter_root/share/shutter/resources/icons/sel_window_menu.svg",
						Gtk2::IconSize->lookup('menu')
					)
				)
			);
		}
		$menuitem_window_menu->signal_connect(
			activate => \&evt_take_screenshot,
			'tray_menu'
		);

		#tooltip
		my $menuitem_window_tooltip = Gtk2::ImageMenuItem->new_with_mnemonic( $d->get('_Tooltip') );
		#~ if($traytheme->has_icon('alacarte')){
			#~ $menuitem_window_tooltip->set_image( Gtk2::Image->new_from_icon_name( 'alacarte', 'menu' ) );	
		#~ }else{
			$menuitem_window_tooltip->set_image(
				Gtk2::Image->new_from_pixbuf(
					Gtk2::Gdk::Pixbuf->new_from_file_at_size(
						"$shutter_root/share/shutter/resources/icons/sel_window_tooltip.svg",
						Gtk2::IconSize->lookup('menu')
					)
				)
			);
		#~ }
		$menuitem_window_tooltip->signal_connect(
			activate => \&evt_take_screenshot,
			'tray_tooltip'
		);
		
		#web
		my $menuitem_web = Gtk2::ImageMenuItem->new_with_mnemonic( $d->get('_Web') );
		$menuitem_web->set_sensitive($gnome_web_photo);
		if($traytheme->has_icon('web-browser')){
			$menuitem_web->set_image( Gtk2::Image->new_from_icon_name( 'web-browser', 'menu' ) );		
		}else{
			$menuitem_web->set_image(
				Gtk2::Image->new_from_pixbuf(
					Gtk2::Gdk::Pixbuf->new_from_file_at_size( "$shutter_root/share/shutter/resources/icons/web_image.svg", Gtk2::IconSize->lookup('menu') )
				)
			);
		}
		$menuitem_web->signal_connect(
			activate => \&evt_take_screenshot,
			'tray_web'
		);

		#preferences	
		my $menuitem_redoshot = Gtk2::ImageMenuItem->new_with_mnemonic ( $d->get('_Redo last screenshot') );
		$menuitem_redoshot->set_image(Gtk2::Image->new_from_stock('gtk-refresh', 'menu'));
		$menuitem_redoshot->signal_connect( 'activate', \&evt_take_screenshot, 'redoshot' );
		$menuitem_redoshot->set_name('redoshot');
		$menuitem_redoshot->set_sensitive(FALSE);
		
		#preferences	
		my $menuitem_settings = Gtk2::ImageMenuItem->new_from_stock( 'gtk-preferences' );
		$menuitem_settings->signal_connect( "activate", \&evt_show_settings );

		#quick profile selector
		my $menuitem_quicks = Gtk2::MenuItem->new_with_mnemonic( $d->get('_Quick profile select') );
		#set name to identify the item later - we use this in really rare cases
		$menuitem_quicks->set_name('quicks');
		$menuitem_quicks->set_sensitive(FALSE);
		
		#info
		my $menuitem_info = Gtk2::ImageMenuItem->new_from_stock( 'gtk-about' );
		$menuitem_info->signal_connect( "activate", \&evt_about );
		
		#quit
		my $menuitem_quit = Gtk2::ImageMenuItem->new_from_stock( 'gtk-quit' );
		$menuitem_quit->signal_connect( "activate", \&evt_delete_window, 'quit' );

		$menu_tray->append($menuitem_redoshot);
		$menu_tray->append( Gtk2::SeparatorMenuItem->new );	
		$menu_tray->append($menuitem_select);
		$menu_tray->append( Gtk2::SeparatorMenuItem->new );
		$menu_tray->append($menuitem_raw);
		$menu_tray->append( Gtk2::SeparatorMenuItem->new );
		$menu_tray->append($menuitem_window);
		$menu_tray->append($menuitem_window_sect);
		$menu_tray->append($menuitem_window_menu);
		$menu_tray->append($menuitem_window_tooltip);
		$menu_tray->append( Gtk2::SeparatorMenuItem->new );
		$menu_tray->append($menuitem_web);
		$menu_tray->append( Gtk2::SeparatorMenuItem->new );
		$menu_tray->append( $menuitem_settings );
		$menu_tray->append( $menuitem_quicks );
		$menu_tray->append( Gtk2::SeparatorMenuItem->new );
		$menu_tray->append($menuitem_info);
		$menu_tray->append($menuitem_quit);
		$menu_tray->show_all;

		return $menu_tray;
	}

	sub fct_ret_sel_menu {

		my $menu_sel = Gtk2::Menu->new;

		#advanced tool
		$tool_advanced = Gtk2::RadioMenuItem->new( undef, $d->get("Advanced selection tool") );

		#simple tool
		$tool_simple = Gtk2::RadioMenuItem->new( $tool_advanced, $d->get("Simple selection tool") );

		$menu_sel->append($tool_advanced);
		$menu_sel->append($tool_simple);

		#set saved/default settings
		if ( defined $settings_xml->{'general'}->{'selection_tool'} ) {
			if ( $settings_xml->{'general'}->{'selection_tool'} == 1 ) {
				$tool_advanced->set_active(TRUE);
			} elsif ( $settings_xml->{'general'}->{'selection_tool'} == 2 ) {
				$tool_simple->set_active(TRUE);
			}
		} else {
			$tool_advanced->set_active(TRUE);
		}
		
		$tooltips->set_tip( $tool_advanced,
			$d->get("The advanced selection tool allows you to enlarge/shrink or move your selected area\nuntil you finally take the screenshot.") );

		$tooltips->set_tip( $tool_simple,
			$d->get("The simple selection tool is the fastest way of taking a screenshot.\nIt provides an optional zoom window for precise shots.") );

		$menu_sel->show_all;

		return $menu_sel;
	}

	sub fct_ret_program_menu {
		#FIXME - this whole sub is weird ;-)

		my $traytheme     = $sc->get_theme;
		my $menu_programs = Gtk2::Menu->new;

		#take $key (mime) directly
		my $key = &fct_get_current_file;

		#FIXME - different mime types
		#have different apps registered
		#we should restrict the offeres apps
		#by comparing the selected
		#
		#currently we just take the last selected file into account
		#
		#search selected files for mime...
		unless ($key) {
			$session_start_screen{'first_page'}->{'view'}->selected_foreach(
				sub {
					my ( $view, $path ) = @_;
					my $iter = $session_start_screen{'first_page'}->{'model'}->get_iter($path);
					if ( defined $iter ) {
						$key = $session_start_screen{'first_page'}->{'model'}->get_value( $iter, 2 );
					}
				}
			);
		}

		#still no key? => leave sub
		unless( $key ){
			$sm->{_menuitem_reopen_default}->visible(FALSE);
			$sm->{_menuitem_large_reopen_default}->visible(FALSE);
			$sm->{_menuitem_reopen}->set_sensitive(FALSE);
			$sm->{_menuitem_large_reopen}->set_sensitive(FALSE);
			return $menu_programs;		
		}

		#no valid hash entry?
		unless (exists $session_screens{$key}->{'mime_type'}){
			$sm->{_menuitem_reopen_default}->visible(FALSE);
			$sm->{_menuitem_large_reopen_default}->visible(FALSE);
			$sm->{_menuitem_reopen}->set_sensitive(FALSE);
			$sm->{_menuitem_large_reopen}->set_sensitive(FALSE);
			return $menu_programs;	
		}

		#determine apps registered with that mime type	
		my ( $default, @mapps ) = File::MimeInfo::Applications::mime_applications( $session_screens{$key}->{'mime_type'} );
		
		#currently we use File::MimeInfo::Applications and Gnome2::VFS::Mime::Type
		#because of the following error
		#
		#libgnomevfs-WARNING **: 
		#Cannot call gnome_vfs_mime_application_get_icon 
		#with a GNOMEVFSMimeApplication structure constructed 
		#by the deprecated application registry 
		my $mime_type = Gnome2::VFS::Mime::Type->new ($session_screens{$key}->{'mime_type'});
		my @apps = $mime_type->get_all_applications();

		#get some other apps that may be capable (e.g. browsers)	
		my $mime_type_fallback = Gnome2::VFS::Mime::Type->new ('text/html');
		foreach ($mime_type_fallback->get_all_applications()){
			my $already_in_list = FALSE;
			foreach my $existing_app (@apps){
				if($_->{'id'} eq $existing_app->{'id'}){
					$already_in_list = TRUE;
					last;
				}
			}
			push @apps, $_ unless $already_in_list;
		}
		
		#no app determined!
		unless (scalar @apps && scalar @mapps){
			$sm->{_menuitem_reopen_default}->visible(FALSE);
			$sm->{_menuitem_large_reopen_default}->visible(FALSE);
			$sm->{_menuitem_reopen}->set_sensitive(FALSE);
			$sm->{_menuitem_large_reopen}->set_sensitive(FALSE);
			return $menu_programs;			
		}

		#no default app determined!
		unless ($default){
			$sm->{_menuitem_reopen_default}->visible(FALSE);					
			$sm->{_menuitem_large_reopen_default}->visible(FALSE);					
		}
		
		my $default_matched = FALSE;
		foreach my $app (@apps) {
			
			#~ print "checking ", $app->{'name'}, " for open with dialog\n";
			
			#ignore Shutter's desktop entry
			next if $app->{'id'} eq 'shutter.desktop';
			
			$app->{'name'} = $shf->utf8_decode($app->{'name'});
			
			#FIXME - kde apps do not support the freedesktop standards (.desktop files)
			#we simply cut the kde* / kde4* substring here
			#is it possible to get the wrong app if there 
			#is the kde3 and the kde4 version of an app installed?
			#
			#I think so ;-)
			$app->{'id'} =~ s/^(kde4|kde)-//g;

			my $program_item = undef; 
			my $program_large_item = undef; 
			
			#default app
			if($default && $default->{'file'} =~ m/$app->{'id'}/){
				
				#set flag
				$default_matched = TRUE;
				
				#remove old handler
				#strange things happen when we do not remove it
				if(exists $sm->{_menuitem_reopen_default}{hid} 
					&& $sm->{_menuitem_reopen_default}->signal_handler_is_connected($sm->{_menuitem_reopen_default}{hid}))
				{
					$sm->{_menuitem_reopen_default}->signal_handler_disconnect($sm->{_menuitem_reopen_default}{hid});
				}
				
				#remove old handler from large menu
				if(exists $sm->{_menuitem_large_reopen_default}{hid} 
					&& $sm->{_menuitem_large_reopen_default}->signal_handler_is_connected($sm->{_menuitem_large_reopen_default}{hid}))
				{
					$sm->{_menuitem_large_reopen_default}->signal_handler_disconnect($sm->{_menuitem_large_reopen_default}{hid});
				}
				
				$program_item = $sm->{_menuitem_reopen_default};
				$program_item->{'default'} = TRUE;
				
				$program_large_item = $sm->{_menuitem_large_reopen_default};
				$program_large_item->{'default'} = TRUE;

				#show always an icon
				$program_item->set('always_show_image' => TRUE) if Gtk2->CHECK_VERSION( 2, 16, 0 );	
				$program_large_item->set('always_show_image' => TRUE) if Gtk2->CHECK_VERSION( 2, 16, 0 );	
				
				$sm->{_menuitem_reopen_default}->show;
				$sm->{_menuitem_reopen_default}->set_sensitive(TRUE);
				
				$sm->{_menuitem_large_reopen_default}->show;
				$sm->{_menuitem_large_reopen_default}->set_sensitive(TRUE);

				#change label of the default app entry
				$sm->{_menuitem_reopen_default}->foreach (sub {
					if($_[0] =~ /Gtk2::AccelLabel/){
						$_[0]->set_label(sprintf( $d->get("_Open with %s"), "'".$app->{'name'}."'"));
						return;
					}
				});	

				#change label of the default app entry - large menu
				$sm->{_menuitem_large_reopen_default}->foreach (sub {
					if($_[0] =~ /Gtk2::AccelLabel/){
						$_[0]->set_label(sprintf( $d->get("_Open with %s"), "'".$app->{'name'}."'"));
						return;
					}
				});	
					
			#other apps			
			}else{
				$program_item = Gtk2::ImageMenuItem->new_with_label( $app->{'name'} );
				$program_item->set('always_show_image' => TRUE) if Gtk2->CHECK_VERSION( 2, 16, 0 );	
				$menu_programs->append($program_item);
			}

			#find icon and app
			#we use File::DesktopEntry instead of the Gnome one
			#for opening files
			my $oapp = undef; 
			foreach my $mapp (@mapps){
				if($mapp->{'file'} =~ m/$app->{'id'}/){
					$oapp = $mapp;
					last;	
				}	
			}
		
			#match found!
			if ($oapp){
				my $tray_name = $oapp->Icon;
				if($tray_name){
					#cut image formats
					$tray_name =~ s/(.png|.svg|.gif|.jpeg|.jpg)//g;
					if ( $traytheme->has_icon( $tray_name ) ) {
						my ( $iw, $ih ) = Gtk2::IconSize->lookup('menu');
						
						my $tray_pixbuf = undef;
						eval{
							$tray_pixbuf = $traytheme->load_icon( $tray_name, $ih, 'generic-fallback' );
						};
						if($@){
							print "\nWARNING: Could not load icon $tray_name: $@\n";
							$tray_pixbuf = undef;	
						}	
						
						if($program_item){
							$program_item->set_image( Gtk2::Image->new_from_pixbuf($tray_pixbuf) );
						}
						
						if($program_large_item){
							$program_large_item->set_image( Gtk2::Image->new_from_pixbuf($tray_pixbuf) );
						}
					}
				}
				
				my $hid;
				if($program_item){
					$hid = $program_item->signal_connect(
						'activate' => sub {
							&fct_open_with_program($oapp, $app->{'name'});
						}
					);
				}
				
				my $hid_large;
				if($program_large_item){
					$hid_large = $program_large_item->signal_connect(
						'activate' => sub {
							&fct_open_with_program($oapp, $app->{'name'});
						}
					);
				}
				
				#save hid when default app
				#to remove the handler next time we open the menu
				$sm->{_menuitem_reopen_default}{hid} = $hid if $program_item->{'default'};
				$sm->{_menuitem_large_reopen_default}{hid} = $hid_large if $program_large_item->{'default'};
				
			#no match found -> destroy current menu entry		
			}else{
				$program_item->destroy;
			}		
			
		} #end foreach	
		
		#no default app matched!
		unless($default_matched){
			$sm->{_menuitem_reopen_default}->visible(FALSE);	
			$sm->{_menuitem_large_reopen_default}->visible(FALSE);	
		}
		
		#menu does not contain any item
		unless($menu_programs->get_children){
			$sm->{_menuitem_reopen}->set_sensitive(FALSE);
			$sm->{_menuitem_large_reopen}->set_sensitive(FALSE);
		}
		
		$menu_programs->show_all;
		return $menu_programs;
	}

	sub fct_ret_web_menu {
		
		my $menu_web = Gtk2::Menu->new;
		
		my $timeout0 = Gtk2::RadioMenuItem->new( undef, $d->get("Timeout") . ": 0" );
		my $timeout1 = Gtk2::RadioMenuItem->new( $timeout0, $d->get("Timeout") . ": 10" );
		my $timeout2 = Gtk2::RadioMenuItem->new( $timeout0, $d->get("Timeout") . ": 30" );
		my $timeout3 = Gtk2::RadioMenuItem->new( $timeout0, $d->get("Timeout") . ": 60" );
		my $timeout4 = Gtk2::RadioMenuItem->new( $timeout0, $d->get("Timeout") . ": 120" );

		$tooltips->set_tip( $timeout0, $d->get("The timeout in seconds, or 0 to disable timeout" ));
		$tooltips->set_tip( $timeout1, $d->get("The timeout in seconds, or 0 to disable timeout" ));
		$tooltips->set_tip( $timeout2, $d->get("The timeout in seconds, or 0 to disable timeout" ));
		$tooltips->set_tip( $timeout3, $d->get("The timeout in seconds, or 0 to disable timeout" ));
		$tooltips->set_tip( $timeout4, $d->get("The timeout in seconds, or 0 to disable timeout" ));
		
		$timeout2->set_active(TRUE);
		$menu_web->append($timeout0);
		$menu_web->append($timeout1);
		$menu_web->append($timeout2);
		$menu_web->append($timeout3);
		$menu_web->append($timeout4);

		if ( defined $settings_xml->{'general'}->{'web_timeout'} ) {

			#determining timeout
			my @timeouts = $menu_web->get_children;
			my $timeout  = undef;
			foreach (@timeouts) {
				$timeout = $_->get_children->get_text;
				$timeout =~ /([0-9]+)/;
				$timeout = $1;
				if ( $settings_xml->{'general'}->{'web_timeout'} == $timeout ) {
					$_->set_active(TRUE);
				}
			}
		}
		$menu_web->show_all;
		return $menu_web;
	}

	sub fct_ret_profile_menu {
		my $combobox_settings_profiles = shift;
		my $current_profiles_ref       = shift;

		my $menu_profile = Gtk2::Menu->new;

		my $group   = undef;
		my $counter = 0;
		foreach my $profile ( @{$current_profiles_ref} ) {
			my $profile_item = Gtk2::RadioMenuItem->new( $group, $profile );
			$profile_item->set_active(TRUE)
				if $profile eq $combobox_settings_profiles->get_active_text;
			$profile_item->signal_connect(
				'toggled' => sub {
					my $widget = shift;
					return TRUE unless $widget->get_active;

					for ( my $i = 0; $i < scalar @{$current_profiles_ref}; $i++ ) {
						$combobox_settings_profiles->set_active($i);
						$current_profile_indx = $i;
						if ( $profile eq $combobox_settings_profiles->get_active_text ) {
							&evt_apply_profile( $widget, $combobox_settings_profiles, $current_profiles_ref );
							last;
						}
					}
				}
			);
			$group = $profile_item unless $group;
			$menu_profile->append($profile_item);
			$counter++;
		}

		$menu_profile->show_all;
		return $menu_profile;
	}

	sub fct_load_accounts_tree {

		$accounts_model
			= Gtk2::ListStore->new( 'Glib::String', 'Glib::String', 'Glib::String', 'Glib::String', 'Glib::String', 'Glib::String', 'Glib::String' );

		foreach ( keys %accounts ) {
			my $hidden_text = "";
			for ( my $i = 1; $i <= length( $accounts{$_}->{'password'} ); $i++ ) {
				$hidden_text .= '*';
			}
			$accounts_model->set(
				$accounts_model->append, 0, $accounts{$_}->{'host'},     1, $accounts{$_}->{'username'},       2,
				$hidden_text,            3, $accounts{$_}->{'register'}, 4, $accounts{$_}->{'register_color'}, 5,
				$accounts{$_}->{'register_text'}
			);
		}

		return TRUE;
	}

	sub fct_load_plugin_tree {

		my $effects_model = Gtk2::ListStore->new(
			'Gtk2::Gdk::Pixbuf', 'Glib::String', 'Glib::String', 
			'Glib::String', 'Glib::String', 'Glib::String', 
			'Glib::String',
		);
		foreach ( sort keys %plugins ) {
			if ( $plugins{$_}->{'binary'} ) {
			
				#we need to update the pixbuf of the plugins again in some cases
				#
				#pixbufs are not cached and therefore not checked at startup if
				#the cached plugin is not in the plugin path
				#(maybe changed the installation dir)
				unless($plugins{$_}->{'pixbuf'} || $plugins{$_}->{'pixbuf_object'}){
					$plugins{$_}->{'pixbuf'} = $plugins{$_}->{'binary'} . ".png"
						if ( $shf->file_exists( $plugins{$_}->{'binary'} . ".png" ) );
					$plugins{$_}->{'pixbuf'} = $plugins{$_}->{'binary'} . ".svg"
						if ( $shf->file_exists( $plugins{$_}->{'binary'} . ".svg" ) );
			
					if ( $shf->file_exists( $plugins{$_}->{'pixbuf'} ) ) {
						$plugins{$_}->{'pixbuf_object'}= Gtk2::Gdk::Pixbuf->new_from_file_at_size( $plugins{$_}->{'pixbuf'}, Gtk2::IconSize->lookup('menu') );
					} else {
						$plugins{$_}->{'pixbuf'} = "$shutter_root/share/shutter/resources/icons/executable.svg";
						$plugins{$_}->{'pixbuf_object'}= Gtk2::Gdk::Pixbuf->new_from_file_at_size( $plugins{$_}->{'pixbuf'}, Gtk2::IconSize->lookup('menu') );
					}
				}

				$effects_model->set(
					$effects_model->append,     
					0, $plugins{$_}->{'pixbuf_object'}, 1, $plugins{$_}->{'name'},
					2, $plugins{$_}->{'category'}, 3, $plugins{$_}->{'tooltip'},  
					4, $plugins{$_}->{'lang'}, 5, $plugins{$_}->{'binary'}, 6, $_,
				);
			} else {
				print "\nWARNING: Plugin $_ is not configured properly, ignoring\n";
				delete $plugins{$_};
			}
		}

		return $effects_model;
	}

	sub fct_set_model_accounts {
		my $accounts_tree = $_[0];

		my @columns = $accounts_tree->get_columns;
		foreach (@columns) {
			$accounts_tree->remove_column($_);
		}

		#host
		my $tv_clmn_name_text = Gtk2::TreeViewColumn->new;
		$tv_clmn_name_text->set_title( $d->get("Host") );
		my $renderer_name_accounts = Gtk2::CellRendererText->new;
		$tv_clmn_name_text->pack_start( $renderer_name_accounts, FALSE );
		$tv_clmn_name_text->set_attributes( $renderer_name_accounts, text => 0 );
		$accounts_tree->append_column($tv_clmn_name_text);

		my $renderer_username_accounts = Gtk2::CellRendererText->new;
		$renderer_username_accounts->set( editable => TRUE );
		$renderer_username_accounts->signal_connect(
			'edited' => sub {
				my ( $cell, $text_path, $new_text, $model ) = @_;
				my $path = Gtk2::TreePath->new_from_string($text_path);
				my $iter = $model->get_iter($path);

				#save entered username to the hash
				$accounts{ $model->get_value( $iter, 0 ) }->{'username'} = $new_text;

				$model->set( $iter, 1, $new_text );
			},
			$accounts_model
		);
		
		my $tv_clmn_username_text = Gtk2::TreeViewColumn->new_with_attributes( $d->get("Username"), $renderer_username_accounts, text => 1 );
		$tv_clmn_username_text->set_max_width(100);
		$accounts_tree->append_column($tv_clmn_username_text);

		#password
		my $tv_clmn_password_text = Gtk2::TreeViewColumn->new;
		$tv_clmn_password_text->set_max_width(100);
		$tv_clmn_password_text->set_title( $d->get("Password") );
		my $renderer_password_accounts = Gtk2::CellRendererText->new;
		$renderer_password_accounts->set( editable => TRUE );

		$renderer_password_accounts->signal_connect(
			'edited' => sub {
				my ( $cell, $text_path, $new_text, $model ) = @_;
				my $path        = Gtk2::TreePath->new_from_string($text_path);
				my $iter        = $model->get_iter($path);
				my $hidden_text = "";

				for ( my $i = 1; $i <= length($new_text); $i++ ) {
					$hidden_text .= '*';
				}
				
				$accounts{ $model->get_value( $iter, 0 ) }->{'password'} = $new_text;    #save entered password to the hash
				$model->set( $iter, 2, $hidden_text );
			},
			$accounts_model
		);

		$tv_clmn_password_text->pack_start( $renderer_password_accounts, FALSE );
		$tv_clmn_password_text->set_attributes( $renderer_password_accounts, text => 2 );
		$accounts_tree->append_column($tv_clmn_password_text);

		#register
		my $tv_clmn_pix_text = Gtk2::TreeViewColumn->new;
		$tv_clmn_pix_text->set_title( $d->get("Register") );
		my $ren_text = Gtk2::CellRendererText->new();
		$tv_clmn_pix_text->pack_start( $ren_text, FALSE );
		$tv_clmn_pix_text->set_attributes( $ren_text, 'text', ( $d->get(5) ), 'foreground', 4 );
		$accounts_tree->append_column($tv_clmn_pix_text);

		return TRUE;
	}

	sub fct_set_model_plugins {	
		my $effects_tree = $_[0];

		#~ my @columns = $effects_tree->get_columns;
		#~ foreach (@columns) {
			#~ $effects_tree->remove_column($_);
		#~ }

		#icon
		$effects_tree->set_tooltip_column(3)
			if Gtk2->CHECK_VERSION( 2, 11, 0 );
		
		my $tv_clmn_pix_text = Gtk2::TreeViewColumn->new;
		$tv_clmn_pix_text->set_resizable(TRUE);
		$tv_clmn_pix_text->set_title( $d->get("Icon") );
		my $renderer_pix_effects = Gtk2::CellRendererPixbuf->new;
		$tv_clmn_pix_text->pack_start( $renderer_pix_effects, FALSE );
		$tv_clmn_pix_text->set_attributes( $renderer_pix_effects, pixbuf => 0 );
		$effects_tree->append_column($tv_clmn_pix_text);

		#name
		my $tv_clmn_text_text = Gtk2::TreeViewColumn->new;
		$tv_clmn_text_text->set_resizable(TRUE);
		$tv_clmn_text_text->set_title( $d->get("Name") );
		my $renderer_text_effects = Gtk2::CellRendererText->new;
		$tv_clmn_text_text->pack_start( $renderer_text_effects, FALSE );
		$tv_clmn_text_text->set_attributes( $renderer_text_effects, text => 1 );

		$effects_tree->append_column($tv_clmn_text_text);

		#category
		my $tv_clmn_category_text = Gtk2::TreeViewColumn->new;
		$tv_clmn_category_text->set_resizable(TRUE);
		$tv_clmn_category_text->set_title( $d->get("Category") );
		my $renderer_category_effects = Gtk2::CellRendererText->new;
		$tv_clmn_category_text->pack_start( $renderer_category_effects, FALSE );
		$tv_clmn_category_text->set_attributes( $renderer_category_effects, text => 2 );
		$effects_tree->append_column($tv_clmn_category_text);

		#tooltip column
		unless ( Gtk2->CHECK_VERSION( 2, 12, 0 ) ) {
			my $tv_clmn_descr_text = Gtk2::TreeViewColumn->new;
			$tv_clmn_descr_text->set_resizable(TRUE);
			$tv_clmn_descr_text->set_title( $d->get("Description") );
			my $renderer_descr_effects = Gtk2::CellRendererText->new;
			$tv_clmn_descr_text->pack_start( $renderer_descr_effects, FALSE );
			$tv_clmn_descr_text->set_attributes( $renderer_descr_effects, text => 3 );
			$effects_tree->append_column($tv_clmn_descr_text);
		}

		#language
		my $tv_clmn_lang_text = Gtk2::TreeViewColumn->new;
		$tv_clmn_lang_text->set_resizable(TRUE);
		$tv_clmn_lang_text->set_title( $d->get("Language") );
		my $renderer_lang_effects = Gtk2::CellRendererText->new;
		$tv_clmn_lang_text->pack_start( $renderer_lang_effects, FALSE );
		$tv_clmn_lang_text->set_attributes( $renderer_lang_effects, text => 4 );
		$effects_tree->append_column($tv_clmn_lang_text);

		#path
		my $tv_clmn_path_text = Gtk2::TreeViewColumn->new;
		$tv_clmn_path_text->set_resizable(TRUE);
		$tv_clmn_path_text->set_title( $d->get("Path") );
		my $renderer_path_effects = Gtk2::CellRendererText->new;
		$tv_clmn_path_text->pack_start( $renderer_path_effects, FALSE );
		$tv_clmn_path_text->set_attributes( $renderer_path_effects, text => 5 );
		$effects_tree->append_column($tv_clmn_path_text);

		return TRUE;
	}

	sub fct_init_u1_watcher {

		return FALSE unless $ubuntuone;
		
		my $u1 = Shutter::Upload::UbuntuOne->new($sc);
		$u1->connect_to_bus;
		
		#check api requirements
		return FALSE unless $u1->check_api;
					
		if($u1->is_connected){
		  
		  my $sd_status = $u1->get_syncdaemon_status;
		  my $sd_public = $u1->get_syncdaemon_public;
		  my $sd_fs     = $u1->get_syncdaemon_fs;

		  $sd_status->connect_to_signal('UploadFinished', sub {
			 my $file = shift;
			 my %meta = %{$sd_fs->get_metadata($file)};
			 #~ print Dumper %meta;
			 #find corresponding key
			 if(my $key = &fct_get_key_by_pubfile($meta{'path'})){
				$sd_public->change_public_access($meta{'share_id'}, $meta{'node_id'}, TRUE);
			 }
		  });               
		  
		  $sd_public->connect_to_signal('PublicAccessChanged', sub {
			 my $meta_ref = shift;
			 my %meta = %{$meta_ref};
			 #~ print Dumper %meta;
			 #find corresponding key
			 if(my $key = &fct_get_key_by_pubfile($meta{'path'})){
											  
				#changed to public
				if($meta{'is_public'}){

				   $session_screens{$key}->{'links'}->{'ubuntu-one'}->{'puburl'}     = $meta{'public_url'};
				   $session_screens{$key}->{'links'}->{'ubuntu-one'}->{'menuentry'}  = $d->get("Copy Ubuntu One public URL");
				   $session_screens{$key}->{'links'}->{'ubuntu-one'}->{'menuimage'}  = "ubuntuone";

				   #copy to clipboard
				   $clipboard->set_text($meta{'public_url'});
				
				   #show as notification
				   my $notify 	= $sc->get_notification_object;
				   $notify->show( $d->get("Successfully published"), sprintf($d->get("The file %s was successfully published: %s"), $session_screens{$key}->{'long'}, $meta{'public_url'} ) );
				
				   &fct_show_status_message( 1, $shf->utf8_decode(sprintf($d->get("%s published"), $meta{'path'})) );
				#publishing stopped
				}else{							

				   $session_screens{$key}->{'links'}->{'ubuntu-one'}->{'puburl'}     = undef;
				   $session_screens{$key}->{'links'}->{'ubuntu-one'}->{'menuentry'}  = undef;
				   $session_screens{$key}->{'links'}->{'ubuntu-one'}->{'menuimage'}  = undef;

				   #show as notification
				   my $notify 	= $sc->get_notification_object;
				   $notify->show( $d->get("Unpublished"), sprintf($d->get("The file %s is no longer published. The external link is not available anymore."), $meta{'path'} ) );
				
				   &fct_show_status_message( 1, $shf->utf8_decode(sprintf($d->get("The file %s is no longer published."), $meta{'path'})) );									
				}

				#update actions
				#new public links
				&fct_update_actions(1, $key);
							
			 }
		  });

		}

		return $u1;
	}

	sub fct_init_depend {

		#imagemagick/perlmagick
		unless ( File::Which::which('convert') ) {
			die "ERROR: imagemagick is missing --> aborting!\n\n";
		}

		#gnome-web-photo
		unless ( File::Which::which('gnome-web-photo') ) {
			warn "WARNING: gnome-web-photo is missing --> screenshots of websites will be disabled!\n\n";
			$gnome_web_photo = FALSE;
		}

		#nautilus-sendto
		unless ( File::Which::which('nautilus-sendto') ) {
			$nautilus_sendto = FALSE;
		}

		#goocanvas
		eval { require Goo::Canvas };
		if ($@) {
			warn "WARNING: Goo::Canvas/libgoocanvas is missing --> drawing tool will be disabled!\n\n";
			$goocanvas = FALSE;
		}
		
		eval { require Net::DBus::GLib };
		if ($@) {
			warn "WARNING: Net::DBus::GLib is missing --> Ubuntu One support will be disabled!\n\n";
			$ubuntuone = FALSE;
		}

		return TRUE;
	}

	sub fct_init {
			
		#are there any command line params?
		if ( @ARGV > 0 ) {
			foreach my $arg (@ARGV) {
				
				#filename?
				if ( $shf->file_exists($arg) || $shf->uri_exists($arg) ) {
					#push filename to array, open when GUI is initialized
					push @init_files, $arg;
					next;
				}	
				
				$arg =~ s/.{2}//;
				if ( $arg eq "debug" ) {
					$sc->set_debug(TRUE);
				} elsif ( $arg eq "help" ) {
					$shf->usage;
					exit;
				} elsif ( $arg eq "version" ) {
					print $sc->get_version, " ", $sc->get_rev, "\n";
					exit;
				} elsif ( $arg eq "clear_cache" ) {
					$sc->set_clear_cache(TRUE);
				} elsif ( $arg eq "min_at_startup" ) {
					$sc->set_min(TRUE);
				} elsif ( $arg eq "disable_systray" ) {
					$sc->set_disable_systray(TRUE);
				} elsif ( $arg eq "section" ) {
					foreach (@{&fct_init_pgrep}) {
						next if /$$/; #do not match own pid
						next if /^$/;
						kill RTMAX => $_;
						die;
					}
					$sc->set_start_with("section");
					$sc->set_min(TRUE);
				} elsif ( $arg eq "selection" ) {
					foreach (@{&fct_init_pgrep}) {
						next if /$$/; #do not match own pid
						next if /^$/;
						kill RTMIN => $_;
						die;
					}
					$sc->set_start_with("select");
					$sc->set_min(TRUE);
				} elsif ( $arg eq "window" ) {
					foreach (@{&fct_init_pgrep}) {
						next if /$$/; #do not match own pid
						next if /^$/;
						kill USR2 => $_;
						die;
					}
					$sc->set_start_with("window");
					$sc->set_min(TRUE);
				} elsif ( $arg eq "full" ) {
					foreach (@{&fct_init_pgrep}) {
						next if /$$/; #do not match own pid
						next if /^$/;
						kill USR1 => $_;
						die;
					}
					$sc->set_start_with("raw");
					$sc->set_min(TRUE);				
				} else {
					warn "ERROR: illegal command " . $arg . " \n\n";
					$shf->usage;
					exit;
				}
				print "INFO: command " . $arg . " recognized!\n\n";
			} #end foreach $arg
					
		} else {
			print "INFO: no command line parameters set...\n\n";
		}

		#an old .shutter file existing?
		unlink("$ENV{ 'HOME' }/.shutter")
			if ( $shf->file_exists("$ENV{ 'HOME' }/.shutter") );

		#an old .shutter/settings.conf file existing?
		unlink("$ENV{ 'HOME' }/.shutter/settings.conf")
			if ( $shf->file_exists("$ENV{ 'HOME' }/.shutter/settings.conf") );


		#migrate from gscrot to shutter
		#if an .gscrot folder exists in the home dir
		#we copy the contents to a newly created .shutter
		#folder
		if(-d "$ENV{ 'HOME' }/.gscrot"){
			if(File::Copy::Recursive::dircopy("$ENV{ 'HOME' }/.gscrot", "$ENV{ 'HOME' }/.shutter")){
				print "INFO: successfully copied all files from .gscrot to .shutter...\n\n";
				rmtree("$ENV{ 'HOME' }/.gscrot");
			}else{
				die $!;	
			}
		}

		#is there already a .shutter folder?
		mkdir("$ENV{ 'HOME' }/.shutter")
			unless ( -d "$ENV{ 'HOME' }/.shutter" );

		#...and a profiles folder?
		mkdir "$ENV{'HOME'}/.shutter/profiles"
			unless ( -d "$ENV{'HOME'}/.shutter/profiles" );

		return TRUE;
	}

	sub fct_init_pgrep {

		#is there already a process of shutter running?
		#FIXME: this is very, very ugly
		#this will be replaced by libunique as soon as possible
		my $command 	 = "$^X $shutter_path";
		my @shutter_pids = `pgrep -u $< -x -f '$command'`;
		
		#capture
		my $commandf 	= "$^X $shutter_path --full";
		my $commandw 	= "$^X $shutter_path --window";
		my $commands 	= "$^X $shutter_path --selection";
		my $commandse 	= "$^X $shutter_path --section";
		push @shutter_pids, `pgrep -u $< -x -f '$commandf'`;
		push @shutter_pids, `pgrep -u $< -x -f '$commandw'`;
		push @shutter_pids, `pgrep -u $< -x -f '$commands'`;
		push @shutter_pids, `pgrep -u $< -x -f '$commandse'`;
		
		#application
		my $commandms 	= "$^X $shutter_path --min_at_startup";
		my $commandcc 	= "$^X $shutter_path --clear_cache";
		my $commandde 	= "$^X $shutter_path --debug";
		my $commandds 	= "$^X $shutter_path --disable_systray";

		push @shutter_pids, `pgrep -u $< -x -f '$commandms'`;
		push @shutter_pids, `pgrep -u $< -x -f '$commandcc'`;
		push @shutter_pids, `pgrep -u $< -x -f '$commandde'`;
		push @shutter_pids, `pgrep -u $< -x -f '$commandds'`;
		#~ foreach(@shutter_pids){
			#~ print $_,"\n"	
		#~ }
		
		return \@shutter_pids;
	}

	sub fct_init_debug_output {
		
		print "\nINFO: gathering system information...";
		print "\n";
		print "\n";
		
		#kernel info
		if ( File::Which::which('uname') ) {
			print `uname -a`, "\n";
		}	
		
		#issue
		if ( -f '/etc/issue' ) {
			if ( File::Which::which('cat') ) {
				print `cat /etc/issue`, "\n";
			}
		}
		
		printf "Glib %s \n", $Glib::VERSION;
		printf "Gtk2 %s \n", $Gtk2::VERSION;
		print "\n";

		# The version info stuff appeared in 1.040.
		print "Glib built for "
			. join( ".", Glib->GET_VERSION_INFO )
			. ", running with "
			. join( ".", &Glib::major_version, &Glib::minor_version, &Glib::micro_version ) . "\n"
			if $Glib::VERSION >= 1.040;
		print "Gtk2 built for "
			. join( ".", Gtk2->GET_VERSION_INFO )
			. ", running with "
			. join( ".", &Gtk2::major_version, &Gtk2::minor_version, &Gtk2::micro_version ) . "\n"
			if $Gtk2::VERSION >= 1.040;
		print "\n";

		return TRUE;
	}

	#--------------------------------------

	#dialogs
	#--------------------------------------

	sub dlg_rename {
		my (@file_to_rename_keys) = @_;

		foreach my $key (@file_to_rename_keys){

			my $input_dialog = Gtk2::MessageDialog->new( $window, [qw/modal destroy-with-parent/], 'other', 'none', undef );

			$input_dialog->set_title($d->get("Rename"));

			$input_dialog->set( 'image' => Gtk2::Image->new_from_stock( 'gtk-save-as', 'dialog' ) );

			$input_dialog->set( 'text' => sprintf( $d->get( "Rename image %s"), "'$session_screens{$key}->{'short'}'" ) );

			$input_dialog->set( 'secondary-text' => $d->get("New filename") . ": " );

			#rename button
			my $rename_btn = Gtk2::Button->new_with_mnemonic( $d->get("_Rename") );
			$rename_btn->set_image( Gtk2::Image->new_from_stock( 'gtk-save-as', 'button' ) );
			$rename_btn->can_default(TRUE);

			$input_dialog->add_button( 'gtk-cancel', 10 );
			$input_dialog->add_action_widget( $rename_btn, 20 );

			$input_dialog->set_default_response(20);

			my $new_filename_vbox = Gtk2::VBox->new();
			my $new_filename_hint = Gtk2::Label->new();
			my $new_filename      = Gtk2::Entry->new();
			$new_filename->set_activates_default(TRUE);
			
			#here are all invalid char codes
			my @invalid_codes = (47,92,63,37,42,58,124,34,60,62,44,59,35,38);
			$new_filename->signal_connect('key-press-event' => sub {
				my $new_filename 	= shift;
				my $event 			= shift;
				
				my $input = Gtk2::Gdk->keyval_to_unicode ($event->keyval); 
				
				#invalid input
				#~ print $input."\n";
				if(grep($input == $_, @invalid_codes)){
					my $char = chr($input);
					$char = '&amp;' if $char eq '&';
					$new_filename_hint->set_markup("<span size='small'>" . 
													sprintf($d->get("Reserved character %s is not allowed to be in a filename.") , "'".$char."'") 
													. "</span>");	
					return TRUE;
				}else{
					#clear possible message when valid char is entered
					$new_filename_hint->set_markup("<span size='small'></span>");						
					return FALSE;
				}
			});

			#enable/disable rename button
			#e.g. if no text is in entry
			$new_filename->signal_connect('changed' => sub {
				if(length($new_filename->get_text)){
					$rename_btn->set_sensitive(TRUE);	
				}else{
					$rename_btn->set_sensitive(FALSE);
				}
				return TRUE;
			});

			#show just the name of the image
			$new_filename->set_text( $session_screens{$key}->{'name'} );
			if(length($new_filename->get_text)){
				$rename_btn->set_sensitive(TRUE);	
			}else{
				$rename_btn->set_sensitive(FALSE);
			}

			$new_filename_vbox->pack_start_defaults($new_filename);
			$new_filename_vbox->pack_start_defaults($new_filename_hint);
			$input_dialog->vbox->add($new_filename_vbox);
			$input_dialog->show_all;

			#run dialog
			my $input_response = $input_dialog->run;

			#handle user responses here
			if ( $input_response == 20 ) {

				my $new_name = $new_filename->get_text;
				$new_name = $session_screens{$key}->{'folder'} . "/" . $new_name . "." . $session_screens{$key}->{'filetype'};

				#create uris for following action (e.g. update tab, move etc.)
				my $new_uri = Gnome2::VFS::URI->new($new_name);
				my $old_uri = $session_screens{$key}->{'uri'};

				if($new_uri){

					#filenames eq? -> nothing to do here
					unless ( $session_screens{$key}->{'long'} eq $new_name ) {

						#does the "renamed" file already exists?
						unless ( $shf->file_exists($new_name) ) {

							#ok => rename it

							#cancel handle
							if ( exists $session_screens{$key}->{'handle'} ) {
								
								$session_screens{$key}->{'handle'}->cancel;
							}

							my $result = $old_uri->move ($new_uri, TRUE);
							if ($result eq 'ok'){
						
								&fct_update_tab( $key, undef, $new_uri, FALSE, 'block' );

								#setup a new filemonitor, so we get noticed if the file changed
								&fct_add_file_monitor($key);	

								&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("renamed") );
								
								#change window title
								$window->set_title($session_screens{$key}->{'long'}." - ".SHUTTER_NAME);
								
							}else{

								my $response = $sd->dlg_error_message(
									sprintf( $d->get(  "Error while renaming the image %s."), "'" . $old_uri->extract_short_name . "'"),
									sprintf( $d->get(  "There was an error renaming the image to %s."), "'" . $new_uri->extract_short_name . "'" ),
									undef, undef, undef,
									undef, undef, undef,
									Gnome2::VFS->result_to_string ($result)
								);	
						
							}

						} else {

							#ask the user to replace the image
							#replace button
							my $replace_btn = Gtk2::Button->new_with_mnemonic( $d->get("_Replace") );
							$replace_btn->set_image( Gtk2::Image->new_from_stock( 'gtk-save-as', 'button' ) );

							my $response = $sd->dlg_warning_message(
								sprintf( $d->get("The image already exists in %s. Replacing it will overwrite its contents."), "'" . $new_uri->extract_dirname . "'"),
								sprintf( $d->get( "An image named %s already exists. Do you want to replace it?"), "'" . $new_uri->extract_short_name . "'"),
								undef, undef, undef,
								$replace_btn, undef, undef
							);

							#rename == replace_btn was hit
							if ( $response == 40 ) {

								#ok => rename it

								#cancel handle
								if ( exists $session_screens{$key}->{'handle'} ) {
									
									$session_screens{$key}->{'handle'}->cancel;
								}

								my $result = $old_uri->move ($new_uri, TRUE);
								if ($result eq 'ok'){
					
									&fct_update_tab( $key, undef, $new_uri, FALSE, 'block' );

									#setup a new filemonitor, so we get noticed if the file changed
									&fct_add_file_monitor($key);	

									&fct_show_status_message( 1, $session_screens{$key}->{'long'} . " " . $d->get("renamed") );

									#change window title
									$window->set_title($session_screens{$key}->{'long'}." - ".SHUTTER_NAME);

								}else{

									my $response = $sd->dlg_error_message(
										sprintf( $d->get(  "Error while renaming the image %s."), "'" . $old_uri->extract_short_name . "'"),
										sprintf( $d->get(  "There was an error renaming the image to %s."), "'" . $new_uri->extract_short_name . "'" ),
										undef, undef, undef,
										undef, undef, undef,
										Gnome2::VFS->result_to_string ($result)
									);	
							
								}

								#maybe file is in session as well, need to set the handler again ;-)
								foreach my $searchkey ( keys %session_screens ) {
									next if $key eq $searchkey;
									if ( $session_screens{$searchkey}->{'long'} eq $new_name ) {
										#cancel handle
										if ( exists $session_screens{$searchkey}->{'handle'} ) {
											
											$session_screens{$searchkey}->{'handle'}->cancel;
										}

										&fct_update_tab($searchkey, undef, $new_uri, FALSE, 'block' );

										#setup a new filemonitor, so we get noticed if the file changed
										&fct_add_file_monitor($searchkey);	
								
									}
								}
								$input_dialog->destroy();
								next;
							}
							$input_dialog->destroy();
							next;
						}

					}

				}else{

					#uri object could not be created
					#=> uri illegal
					my $response = $sd->dlg_error_message(
						sprintf( $d->get(  "Error while renaming the image %s."), "'" . $old_uri->extract_short_name . "'"),
						sprintf( $d->get(  "There was an error renaming the image to %s."), "'" . $new_name . "'" ),
						undef, undef, undef,
						undef, undef, undef,
						$d->get("Invalid Filename")
					);			
					
				}
			
			}

			$input_dialog->destroy();
			next;

		}
		
	}

	sub dlg_save_as {
		#mandatory
		my $key = shift;

		#optional
		my $rfiletype = shift;
		my $rfilename = shift;
		my $rpixbuf   = shift;
		my $rquality  = shift;
		
		$rfilename = $session_screens{$key}->{'long'} if $key;
		
		my $fs = Gtk2::FileChooserDialog->new(
			$d->get("Choose a location to save to"),
			$window, 'save',
			'gtk-cancel' => 'reject',
			'gtk-save'   => 'accept'
		);
		
		#go to recently used folder
		if(defined $sc->get_rusf && $shf->folder_exists($sc->get_rusf)){
			#parse filename
			my ( $rshort, $rfolder, $rext ) = fileparse( $rfilename, qr/\.[^.]*/ );
			$fs->set_current_folder($sc->get_rusf);
			$fs->set_current_name($rshort.$rext);
		}else{
			#file already exists
			if($key){
				$fs->set_filename( $rfilename );
			#new file
			}else{
				#parse filename
				my ( $rshort, $rfolder, $rext ) = fileparse( $rfilename, qr/\.[^.]*/ );
				$fs->set_current_folder($rfolder);
				$fs->set_current_name($rshort.$rext);
			}		
		}

		#preview widget
		my $iprev = Gtk2::Image->new;
		$fs->set_preview_widget($iprev);

		$fs->signal_connect(
			'selection-changed' => sub {
				if(my $pfilename = $fs->get_preview_filename){
					my $pixbuf = undef;
					eval{
						$pixbuf = Gtk2::Gdk::Pixbuf->new_from_file_at_scale ($pfilename, 200, 200, TRUE);
					};
					if($@){
						$fs->set_preview_widget_active(FALSE);
					}else{
						$fs->get_preview_widget->set_from_pixbuf($pixbuf);
						$fs->set_preview_widget_active(TRUE)
					}
				}else{
					$fs->set_preview_widget_active(FALSE);
				}
			}
		);

		my $extra_hbox = Gtk2::HBox->new;

		my $label_save_as_type = Gtk2::Label->new( $d->get("Image format") . ":" );

		my $combobox_save_as_type = Gtk2::ComboBox->new_text;

		#add supported formats to combobox
		my $counter = 0;
		my $png_counter = undef;

		#add pdf support
		if(defined $rfiletype && $rfiletype eq 'pdf') {

			$combobox_save_as_type->insert_text($counter, "pdf - Portable Document Format");
			$combobox_save_as_type->set_active(0);
		
		#images
		}else{
			
			foreach ( Gtk2::Gdk::Pixbuf->get_formats ) {
				
				#we don't want svg here - this is a dedicated action in the DrawingTool
				next if !defined $rfiletype && $_->{name} =~ /svg/;
				
				#we have a requested filetype - nothing else will be offered
				next if defined $rfiletype && $_->{name} ne $rfiletype;
				
				#add all known formats to the dialog
				$combobox_save_as_type->insert_text( $counter, $_->{name} . " - " . $_->{description} );
				
				#set active when mime_type is matching
				#loop because multiple mime types are registered for fome file formats
				foreach my $mime (@{$_->{mime_types}}){
					$combobox_save_as_type->set_active($counter)
						if ( ( defined $key && $mime eq $session_screens{$key}->{'mime_type'} ) || defined $rfiletype );		
					
					#save png_counter as well as fallback
					$png_counter = $counter if $mime eq 'image/png';
				}
				
				$counter++;
				
			}

		}
		
		#something went wrong here
		#filetype was not detected automatically
		#set to png as default
		unless($combobox_save_as_type->get_active_text){
			if(defined $png_counter){
				$combobox_save_as_type->set_active($png_counter);
			}	
		}

		$combobox_save_as_type->signal_connect(
			'changed' => sub {
				my $filename = $fs->get_filename;

				my $choosen_format = $combobox_save_as_type->get_active_text;
				$choosen_format =~ s/ \-.*//;    #get png or jpeg for example
				#~ print $choosen_format . "\n";

				#parse filename
				my ( $short, $folder, $ext ) = fileparse( $filename, qr/\.[^.]*/ );

				$fs->set_current_name( $short . "." . $choosen_format );
			}
		);

		$extra_hbox->pack_start( $label_save_as_type,    FALSE, FALSE, 5 );
		$extra_hbox->pack_start( $combobox_save_as_type, FALSE, FALSE, 5 );

		my $align_save_as_type = Gtk2::Alignment->new( 1, 0, 0, 0 );

		$align_save_as_type->add($extra_hbox);
		$align_save_as_type->show_all;

		$fs->set_extra_widget($align_save_as_type);

		my $fs_resp = $fs->run;

		if ( $fs_resp eq "accept" ) {
			my $filename = $fs->get_filename;

			#parse filename
			my ( $short, $folder, $ext ) = fileparse( $filename, qr/\.[^.]*/ );
			
			#keep selected folder in mind
			$sc->set_rusf($folder);
			
			#handle file format
			my $choosen_format = $combobox_save_as_type->get_active_text;
			$choosen_format =~ s/ \-.*//;    #get png or jpeg for example

			$filename = $folder . $short . "." . $choosen_format;

			unless ( $shf->file_exists($filename) ) {
				#get pixbuf from param
				my $pixbuf = $rpixbuf;
				unless($pixbuf){
					#or load pixbuf from existing file
					$pixbuf = Gtk2::Gdk::Pixbuf->new_from_file( $rfilename );
				}
				
				#save as (pixbuf, new_filename, filetype, quality - auto here, old_filename)			
				if($sp->save_pixbuf_to_file($pixbuf, $filename, $choosen_format, $rquality)){
					
					if($key){
						
						#do not try to update when exporting to pdf
						unless (defined $rfiletype && $rfiletype eq 'pdf'){
						
							#cancel handle
							if ( exists $session_screens{$key}->{'handle'} ) {
								
								$session_screens{$key}->{'handle'}->cancel;
							}
							if(&fct_update_tab( $key, undef, Gnome2::VFS::URI->new($filename), FALSE, 'clear' )){
								#setup a new filemonitor, so we get noticed if the file changed
								&fct_add_file_monitor($key);
		
								&fct_show_status_message( 1, "$session_screens{ $key }->{ 'long' } " . $d->get("saved") );
							}
						
						}else{
							if($shf->file_exists($filename)){
								&fct_show_status_message( 1, "$filename " . $d->get("saved") );
							}
						}
					
					}
					
					#successfully saved
					$fs->destroy();
					return $filename;
					
				}else{

					#error while saving
					$fs->destroy();
					return FALSE;
					
				}
				
			} else {

				#ask the user to replace the image
				#replace button
				my $replace_btn = Gtk2::Button->new_with_mnemonic( $d->get("_Replace") );
				$replace_btn->set_image( Gtk2::Image->new_from_stock( 'gtk-save-as', 'button' ) );

				my $response = $sd->dlg_warning_message(
					sprintf( $d->get("The image already exists in %s. Replacing it will overwrite its contents."), "'" . $folder . "'"),
					sprintf( $d->get( "An image named %s already exists. Do you want to replace it?"), "'" . $short.".".$choosen_format . "'" ),
					undef, undef, undef,
					$replace_btn, undef, undef
				);

				if ( $response == 40 ) {
					#get pixbuf from param
					my $pixbuf = $rpixbuf;
					unless($pixbuf){
						#or load pixbuf from existing file
						$pixbuf = Gtk2::Gdk::Pixbuf->new_from_file( $rfilename );
					}
					
					if($sp->save_pixbuf_to_file($pixbuf, $filename, $choosen_format, $rquality)){
						
						if($key){
						
							#do not try to update when exporting to pdf
							unless (defined $rfiletype && $rfiletype eq 'pdf'){
		
								#cancel handle
								if ( exists $session_screens{$key}->{'handle'} ) {
									
									$session_screens{$key}->{'handle'}->cancel;
								}
		
								if(&fct_update_tab( $key, undef, Gnome2::VFS::URI->new($filename), FALSE, 'clear' )){
		
									#setup a new filemonitor, so we get noticed if the file changed
									&fct_add_file_monitor($key);
		
									#maybe file is in session as well, need to set the handler again ;-)
									foreach my $searchkey ( keys %session_screens ) {
										next if $key eq $searchkey;
										if ( $session_screens{$searchkey}->{'long'} eq $filename ) {
											$session_screens{$searchkey}->{'changed'} = TRUE;
											&fct_update_tab($searchkey, undef, undef, FALSE, 'clear');
										}
									}	
		
									&fct_show_status_message( 1, "$session_screens{ $key }->{ 'long' } " . $d->get("saved") );					
		
								}
							
							}else{
								if($shf->file_exists($filename)){
									&fct_show_status_message( 1, "$filename " . $d->get("saved") );
								}
							}
						
						} #end if $key

						#successfully saved
						$fs->destroy();
						return $filename;

					}else{

						#error while saving
						$fs->destroy();
						return FALSE;
						
					}	

				}else{

					#user cancelled overwrite
					$fs->destroy();
					return 'user_cancel';
					
				}

			}

		}else{
			#user cancelled
			$fs->destroy();
			return 'user_cancel';		
		} 	

		$fs->destroy();
				
	}

	sub dlg_plugin {
		my (@file_to_plugin_keys) = @_;

		my $plugin_dialog = Gtk2::Dialog->new( $d->get("Choose a plugin"), $window, [qw/modal destroy-with-parent/] );
		$plugin_dialog->set_size_request(350, -1);
		$plugin_dialog->set_resizable(FALSE);

		#rename button
		my $run_btn = Gtk2::Button->new_with_mnemonic( $d->get("_Run") );
		$run_btn->set_image( Gtk2::Image->new_from_stock( 'gtk-execute', 'button' ) );
		$run_btn->can_default(TRUE);

		$plugin_dialog->add_button( 'gtk-cancel', 10 );
		$plugin_dialog->add_action_widget( $run_btn, 20 );

		$plugin_dialog->set_default_response(20);
		
		my $model = Gtk2::ListStore->new( 'Gtk2::Gdk::Pixbuf', 'Glib::String', 'Glib::String', 'Glib::String', 'Glib::String', 'Glib::String' );

		#temp variables to restore the
		#recent plugin
		my $recent_time = 0;
		my $iter_lastex_plugin = undef;
		foreach my $pkey ( sort keys %plugins ) {

			#check if plugin allows current filetype
			#~ my $nfiles_ok += scalar grep($plugins{$pkey}->{'ext'} =~ /$session_screens{$_}->{'mime_type'}/, @file_to_plugin_keys);
			#~ next if scalar @file_to_plugin_keys > $nfiles_ok;
			
			if ( $plugins{$pkey}->{'binary'} ne "" ) {

				my $new_iter = $model->append;
				$model->set(
					$new_iter, 0, $plugins{$pkey}->{'pixbuf_object'}, 1, $plugins{$pkey}->{'name'},    2,
					$plugins{$pkey}->{'binary'}, 3, $plugins{$pkey}->{'lang'},          4, $plugins{$pkey}->{'tooltip'}, 5,
					$pkey
				);
				
				#initialize $iter_lastex_plugin
				#with first new iter
				$iter_lastex_plugin = $new_iter unless defined $iter_lastex_plugin;
				
				#restore the recent plugin
				#($plugins{$plugin_key}->{'recent'} is a timestamp)
				#
				#we keep the new_iter in mind
				if (defined $plugins{$pkey}->{'recent'} && 
					$plugins{$pkey}->{'recent'} > $recent_time){
					$iter_lastex_plugin = $new_iter;
					$recent_time = $plugins{$pkey}->{'recent'};
				}

			} else {
				print "WARNING: Program $pkey is not configured properly, ignoring\n";
			}
		
		}
		
		my $plugin_label       = Gtk2::Label->new( $d->get("Plugin") . ":" );
		my $plugin             = Gtk2::ComboBox->new($model);
		
		#plugin description
		my $plugin_descr       = Gtk2::TextBuffer->new;
		my $plugin_descr_view  = Gtk2::TextView->new_with_buffer($plugin_descr);
		$plugin_descr_view->set_sensitive(FALSE);
		$plugin_descr_view->set_wrap_mode ('word');
		my $textview_hbox = Gtk2::HBox->new( FALSE, 5 );
		$textview_hbox->set_border_width(8);
		$textview_hbox->pack_start_defaults($plugin_descr_view);

		my $plugin_descr_label = Gtk2::Label->new();
		$plugin_descr_label->set_markup( "<b>" . $d->get("Description") . "</b>" );
		my $plugin_descr_frame = Gtk2::Frame->new();
		$plugin_descr_frame->set_label_widget($plugin_descr_label);
		$plugin_descr_frame->set_shadow_type ('none');
		$plugin_descr_frame->add($textview_hbox);

		#plugin image
		my $plugin_image       = Gtk2::Image->new;
			
		#packing
		my $plugin_vbox1 = Gtk2::VBox->new( FALSE, 5 );
		my $plugin_hbox1 = Gtk2::HBox->new( FALSE, 5 );
		my $plugin_hbox2 = Gtk2::HBox->new( FALSE, 5 );
		$plugin_hbox2->set_border_width(10);

		#what plugin is selected?
		my $plugin_pixbuf = undef;
		my $plugin_name   = undef;
		my $plugin_value  = undef;
		my $plugin_lang   = undef;
		my $plugin_tip    = undef;
		my $plugin_key    = undef;
		$plugin->signal_connect(
			'changed' => sub {
				my $model       = $plugin->get_model();
				my $plugin_iter = $plugin->get_active_iter();

				if ($plugin_iter) {
					$plugin_pixbuf = $model->get_value( $plugin_iter, 0 );
					$plugin_name   = $model->get_value( $plugin_iter, 1 );
					$plugin_value  = $model->get_value( $plugin_iter, 2 );
					$plugin_lang   = $model->get_value( $plugin_iter, 3 );
					$plugin_tip    = $model->get_value( $plugin_iter, 4 );
					$plugin_key    = $model->get_value( $plugin_iter, 5 );

					$plugin_descr->set_text($plugin_tip);
					if ( $shf->file_exists( $plugins{$plugin_key}->{'pixbuf'} ) ) {
						$plugin_image->set_from_pixbuf( Gtk2::Gdk::Pixbuf->new_from_file_at_size( $plugins{$plugin_key}->{'pixbuf'}, 100, 100 ) );
					}
				}
			}
		);
		
		my $renderer_pix = Gtk2::CellRendererPixbuf->new;
		$plugin->pack_start( $renderer_pix, FALSE );
		$plugin->add_attribute( $renderer_pix, pixbuf => 0 );
		my $renderer_text = Gtk2::CellRendererText->new;
		$plugin->pack_start( $renderer_text, FALSE );
		$plugin->add_attribute( $renderer_text, text => 1 );
		
		#we try to activate the last executed plugin if that's possible
		$plugin->set_active_iter($iter_lastex_plugin);

		$plugin_hbox1->pack_start_defaults($plugin);

		$plugin_hbox2->pack_start_defaults($plugin_image);
		$plugin_hbox2->pack_start_defaults($plugin_descr_frame);

		$plugin_vbox1->pack_start( $plugin_hbox1, FALSE, TRUE, 1 );
		$plugin_vbox1->pack_start( $plugin_hbox2, TRUE,  TRUE, 1 );

		$plugin_dialog->vbox->add($plugin_vbox1);

		my $plugin_progress = Gtk2::ProgressBar->new;
		$plugin_progress->set_no_show_all(TRUE);
		$plugin_progress->set_ellipsize('middle');
		$plugin_progress->set_orientation('left-to-right');
		$plugin_dialog->vbox->add($plugin_progress);

		$plugin_dialog->show_all;

		my $plugin_response = $plugin_dialog->run;

		if ( $plugin_response == 20 ) {
			
			#anything wrong with the selected plugin?
			unless ( $plugin_value =~ /[a-zA-Z0-9]+/ ) {
				$sd->dlg_error_message( $d->get("No plugin specified"), $d->get("Failed") );
				return FALSE;
			}

			#we save the last execution time
			#and try to preselect it when the plugin dialog is executed again
			$plugins{$plugin_key}->{'recent'} = time;

			#disable buttons and combobox
			$plugin->set_sensitive(FALSE);
			foreach my $dialog_child ($plugin_dialog->vbox->get_children){
				$dialog_child->set_sensitive(FALSE) if $dialog_child =~ /Button/;
			}

			#show the progress bar
			$plugin_progress->show;
			$plugin_progress->set_fraction(0);
			&fct_update_gui;
			my $counter = 1;

			#call execute_plugin for each file to be processed
			foreach my $key (@file_to_plugin_keys) {
				
				#update the progress bar and update gui to show changes
				#~ $plugin_progress->set_text($session_screens{$key}->{'long'});
				#~ $plugin_progress->set_fraction($counter / scalar @file_to_plugin_keys);
				#~ &fct_update_gui;
				
				#store data
				my $data = [ $plugin_value, $plugin_name, $plugin_lang, $key, $plugin_dialog, $plugin_progress ];
				&fct_execute_plugin( undef, $data );
				
				#increase counter and update gui to show updated progress bar
				$counter++;
			}

			$plugin_dialog->destroy();
			return TRUE;
		} else {
			$plugin_dialog->destroy();
			return FALSE;
		}
	}

	sub dlg_upload {
		my (@files_to_upload) = @_;

		return FALSE if @files_to_upload < 1;

		my $dlg_header = $d->get("Upload / Export");
		my $hosting_dialog = Gtk2::Dialog->new( $dlg_header, $window, [qw/modal destroy-with-parent/] );

		my $close_button = $hosting_dialog->add_button( 'gtk-close', 'close' );
		my $upload_button = $hosting_dialog->add_button( $d->get("_Upload"), 'accept' );
		$upload_button->set_image( Gtk2::Image->new_from_stock( 'gtk-go-up', 'button' ) );
		$hosting_dialog->set_default_response('accept');
		my $model = Gtk2::ListStore->new( 'Glib::String', 'Glib::String', 'Glib::String', 'Glib::String' );

		foreach ( keys %accounts ) {
			#cut username so the dialog will not explode ;-)
			my $short_username = $accounts{$_}->{'username'};
			if ( length $accounts{$_}->{'username'} > 10 ) {
				$short_username = substr( $accounts{$_}->{'username'}, 0, 10 ) . "...";
			}

			$model->set( $model->append, 0, $accounts{$_}->{'host'}, 1, $accounts{$_}->{'username'}, 2, $accounts{$_}->{'password'}, 3, $short_username )
				if ($accounts{$_}->{'username'} ne "" && $accounts{$_}->{'password'} ne "" );			
			
			$model->set( $model->append, 0, $accounts{$_}->{'host'}, 1, $d->get("Guest"), 2, "", 3, $d->get("Guest") );
		}

		my $hosting_image = Gtk2::Image->new;

		#set up account combobox
		my $hosting       = Gtk2::ComboBox->new($model);
		my $renderer_host = Gtk2::CellRendererText->new;
		$hosting->pack_start( $renderer_host, FALSE );
		$hosting->add_attribute( $renderer_host, text => 0 );
		
		my $renderer_username = Gtk2::CellRendererText->new;
		$hosting->pack_start( $renderer_username, FALSE );
		$hosting->add_attribute( $renderer_username, text => 3 );
		$hosting->set_active(0);

		#public hosting settings
		my $pub_hbox1 = Gtk2::HBox->new( FALSE, 0 );
		my $pub_hbox2 = Gtk2::HBox->new( FALSE, 0 );
		my $pub_vbox1 = Gtk2::VBox->new( FALSE, 0 );
		$pub_hbox1->pack_start( Gtk2::Label->new( $d->get("Choose account"). ":" ), FALSE, FALSE, 6 );
		$pub_hbox1->pack_start_defaults($hosting);
		$pub_vbox1->pack_start($pub_hbox1, FALSE, FALSE, 3);

		#places settings
		my $pl_hbox1 = Gtk2::HBox->new( FALSE, 0 );
		my $pl_vbox1 = Gtk2::VBox->new( FALSE, 0 );
		my $places_fc = Gtk2::FileChooserButton->new_with_backend ("Shutter - " . $d->get("Choose folder"), 'select-folder', 'gnome-vfs');	
		$places_fc->set('local-only' => FALSE);
		$pl_hbox1->pack_start( Gtk2::Label->new( $d->get("Choose folder"). ":" ), FALSE, FALSE, 6 );
		$pl_hbox1->pack_start_defaults($places_fc);
		$pl_vbox1->pack_start($pl_hbox1, FALSE, FALSE, 3);

		#u1 settings
		my $u1_vbox1 = Gtk2::VBox->new( FALSE, 0 );
		$u1_vbox1->set_border_width(12);
			
		my $u1_hbox_fc = Gtk2::HBox->new( FALSE, 0 );
		my $u1_hbox_hint = Gtk2::HBox->new( FALSE, 0 );
		my $u1_hbox_hint2 = Gtk2::HBox->new( FALSE, 0 );
		my $u1_hbox_st = Gtk2::HBox->new( FALSE, 0 );

		my $u1_label_status = Gtk2::Label->new( $d->get("Status"). ":" );
		my $u1_status = Gtk2::Label->new();
		if ( Gtk2->CHECK_VERSION( 2, 9, 0 ) ) {
			$u1_status->set_line_wrap(TRUE);
			$u1_status->set_line_wrap_mode('word-char');
		}

		my $u1_label_fc = Gtk2::Label->new( $d->get("Choose folder"). ":" );
		my $u1_fc = Gtk2::FileChooserButton->new_with_backend ("Shutter - " . $d->get("Choose folder"), 'select-folder', 'gnome-vfs');	
		$u1_fc->set('local-only' => FALSE);

		my $u1_hint = Gtk2::Label->new();
		my $u1_hint2 = Gtk2::Label->new();

		$u1_hbox_st->pack_start( $u1_label_status, FALSE, FALSE, 6 );
		$u1_hbox_st->pack_start_defaults($u1_status);
			
		$u1_hbox_fc->pack_start( $u1_label_fc, FALSE, FALSE, 6 );
		$u1_hbox_fc->pack_start_defaults($u1_fc);

		$u1_hbox_hint->pack_start($u1_hint, TRUE, TRUE, 6);
		$u1_hbox_hint2->pack_start($u1_hint2, TRUE, TRUE, 6);

		$u1_label_fc->set_alignment( 0, 0.5 );
		$u1_label_status->set_alignment( 0, 0.5 );
		$u1_status->set_alignment( 0, 0.5 );
		$u1_hint->set_alignment( 0, 0.5 );
		$u1_hint2->set_alignment( 0, 0.5 );

		my $sg_u1 = Gtk2::SizeGroup->new('horizontal');
		$sg_u1->add_widget($u1_label_fc);
		$sg_u1->add_widget($u1_label_status);
			
		$u1_vbox1->pack_start($u1_hbox_st, FALSE, FALSE, 3);
		$u1_vbox1->pack_start($u1_hbox_fc, FALSE, FALSE, 3);
		$u1_vbox1->pack_start($u1_hbox_hint, FALSE, FALSE, 3);
		$u1_vbox1->pack_start($u1_hbox_hint2, FALSE, FALSE, 3);
		
		#ftp settings
		#we are using the same widgets as in the settings and populate
		#them with saved values when possible
		my $ftp_hbox1_dlg = Gtk2::HBox->new( FALSE, 0 );
		my $ftp_hbox2_dlg = Gtk2::HBox->new( FALSE, 0 );
		my $ftp_hbox3_dlg = Gtk2::HBox->new( FALSE, 0 );
		my $ftp_hbox4_dlg = Gtk2::HBox->new( FALSE, 0 );
		my $ftp_hbox5_dlg = Gtk2::HBox->new( FALSE, 0 );

		#uri
		my $ftp_entry_label_dlg = Gtk2::Label->new( $d->get("URI"). ":");
		$ftp_hbox1_dlg->pack_start( $ftp_entry_label_dlg, FALSE, TRUE, 10 );
		my $ftp_remote_entry_dlg = Gtk2::Entry->new;
		$ftp_remote_entry_dlg->set_text( $ftp_remote_entry->get_text );

		$tooltips->set_tip( $ftp_entry_label_dlg, $d->get("URI\nExample: ftp://host:port/path") );

		$tooltips->set_tip( $ftp_remote_entry_dlg, $d->get("URI\nExample: ftp://host:port/path") );

		$ftp_hbox1_dlg->pack_start( $ftp_remote_entry_dlg, TRUE, TRUE, 10 );

		#connection mode
		my $ftp_mode_label_dlg = Gtk2::Label->new( $d->get("Connection mode") . ":");
		$ftp_hbox2_dlg->pack_start( $ftp_mode_label_dlg, FALSE, TRUE, 10 );
		my $ftp_mode_combo_dlg = Gtk2::ComboBox->new_text;
		$ftp_mode_combo_dlg->insert_text( 0, $d->get("Active mode") );
		$ftp_mode_combo_dlg->insert_text( 1, $d->get("Passive mode") );
		$ftp_mode_combo_dlg->set_active( $ftp_mode_combo->get_active );

		$tooltips->set_tip( $ftp_mode_label_dlg, $d->get("Connection mode") );

		$tooltips->set_tip( $ftp_mode_combo_dlg, $d->get("Connection mode") );

		$ftp_hbox2_dlg->pack_start( $ftp_mode_combo_dlg, TRUE, TRUE, 10 );

		#username
		my $ftp_username_label_dlg = Gtk2::Label->new( $d->get("Username") . ":");
		$ftp_hbox3_dlg->pack_start( $ftp_username_label_dlg, FALSE, TRUE, 10 );
		my $ftp_username_entry_dlg = Gtk2::Entry->new;
		$ftp_username_entry_dlg->set_text( $ftp_username_entry->get_text );

		$tooltips->set_tip( $ftp_username_label_dlg, $d->get("Username") );

		$tooltips->set_tip( $ftp_username_entry_dlg, $d->get("Username") );

		$ftp_hbox3_dlg->pack_start( $ftp_username_entry_dlg, TRUE, TRUE, 10 );

		#password
		my $ftp_password_label_dlg = Gtk2::Label->new( $d->get("Password") . ":");
		$ftp_hbox4_dlg->pack_start( $ftp_password_label_dlg, FALSE, TRUE, 10 );
		my $ftp_password_entry_dlg = Gtk2::Entry->new;
		$ftp_password_entry_dlg->set_invisible_char("*");
		$ftp_password_entry_dlg->set_visibility(FALSE);
		$ftp_password_entry_dlg->set_text( $ftp_password_entry->get_text );

		$tooltips->set_tip( $ftp_password_label_dlg, $d->get("Password") );

		$tooltips->set_tip( $ftp_password_entry_dlg, $d->get("Password") );

		$ftp_hbox4_dlg->pack_start( $ftp_password_entry_dlg, TRUE, TRUE, 10 );

		#website url
		my $ftp_wurl_label_dlg = Gtk2::Label->new( $d->get("Website URL") . ":");
		$ftp_hbox5_dlg->pack_start( $ftp_wurl_label_dlg, FALSE, TRUE, 10 );
		my $ftp_wurl_entry_dlg = Gtk2::Entry->new;
		$ftp_wurl_entry_dlg->set_text( $ftp_wurl_entry->get_text );

		$tooltips->set_tip( $ftp_wurl_label_dlg, $d->get("Website URL") );

		$tooltips->set_tip( $ftp_wurl_entry_dlg, $d->get("Website URL") );

		$ftp_hbox5_dlg->pack_start( $ftp_wurl_entry_dlg, TRUE, TRUE, 10 );

		my $ftp_vbox_dlg = Gtk2::VBox->new( FALSE, 0 );
		$ftp_vbox_dlg->pack_start( $ftp_hbox1_dlg, FALSE, TRUE, 3 );
		$ftp_vbox_dlg->pack_start( $ftp_hbox2_dlg, FALSE, TRUE, 3 );
		$ftp_vbox_dlg->pack_start( $ftp_hbox3_dlg, FALSE, TRUE, 3 );
		$ftp_vbox_dlg->pack_start( $ftp_hbox4_dlg, FALSE, TRUE, 3 );
		$ftp_vbox_dlg->pack_start( $ftp_hbox5_dlg, FALSE, TRUE, 3 );

		#all labels = one size
		$ftp_entry_label_dlg->set_alignment( 0, 0.5 );
		$ftp_mode_label_dlg->set_alignment( 0, 0.5 );
		$ftp_username_label_dlg->set_alignment( 0, 0.5 );
		$ftp_password_label_dlg->set_alignment( 0, 0.5 );
		$ftp_wurl_label_dlg->set_alignment( 0, 0.5 );

		my $sg_ftp_dlg = Gtk2::SizeGroup->new('horizontal');
		$sg_ftp_dlg->add_widget($ftp_entry_label_dlg);
		$sg_ftp_dlg->add_widget($ftp_mode_label_dlg);
		$sg_ftp_dlg->add_widget($ftp_username_label_dlg);
		$sg_ftp_dlg->add_widget($ftp_password_label_dlg);
		$sg_ftp_dlg->add_widget($ftp_wurl_label_dlg);

		#setup notebook
		my $unotebook = Gtk2::Notebook->new;
		$unotebook->append_page($pub_vbox1, $d->get("Public hosting"));
		$unotebook->append_page($ftp_vbox_dlg, "FTP");
		$unotebook->append_page($pl_vbox1, $d->get("Places"));
		$unotebook->append_page($u1_vbox1, $d->get("Ubuntu One"));

		$unotebook->signal_connect( 'switch-page' => sub {
			my ( $unotebook, $pointer, $int ) = @_;

			#change label text
			my $hbox = $upload_button->get_child->get_child;
			foreach($hbox->get_children){		
				if(($int == 0 || $int == 1) && $_ =~ /Gtk2::Label/){
					$_->set_text_with_mnemonic($d->get("_Upload"));
					last;
				}elsif($int == 2 && $_ =~ /Gtk2::Label/){
					$_->set_text_with_mnemonic($d->get("_Export"));
					last;
				}elsif($int == 3 && $_ =~ /Gtk2::Label/){      
					$_->set_text_with_mnemonic($d->get("_Publish"));
					last;
				}
			}

			if($int == 0 || $int == 1 || $int == 2){

				$upload_button->set_sensitive(TRUE);

			}elsif($int == 3){
					 
				#ubuntuone enabled (libs installed)?
				if($ubuntuone){

					#start watcher if it is not started yet
					unless($u1_watcher){
						$u1_watcher = &fct_init_u1_watcher;
					}

					#connect
					$u1 = Shutter::Upload::UbuntuOne->new($sc);
					my $con_result = $u1->connect_to_bus;

					#check api version
					if($u1->check_api){

						#set initial status
						$u1_status->set_text($d->get("Disconnected"));

						if($u1->is_connected){

							#reset tooltip
							$tooltips->set_tip( $u1_hbox_hint, "" );

							#update when status has changed
							my $sd_status = $u1->get_syncdaemon_status;
							$sd_status->connect_to_signal('StatusChanged', sub {
								my $status_ref = shift;

								#current status
								my ($is_connected, $is_online, $text) = $u1->get_current_status($status_ref);
								$u1_status->set_text($text);

								if($is_connected && $is_online){
									#is current folder synced?
									if(defined $u1_fc->get_current_folder && $u1->is_synced_folder($u1_fc->get_current_folder)){
										$u1_hint->set_markup("<span size='small'>" . 
											sprintf($d->nget("Folder %s is synchronized with Ubuntu One.\nThe selected file will be copied to that folder before being published.", "Folder %s is synchronized with Ubuntu One.\nThe selected files will be copied to that folder before being published.", scalar @files_to_upload) , "'".$u1_fc->get_current_folder."'") 
											. "</span>");								
											$u1_hint2->set_markup("<span size='small'>" . 
											$d->nget("<b>Please note:</b> The selected file will be published in a background process.\nYou will be notified when the process has finished.", "<b>Please note:</b> The selected files will be published in a background process.\nYou will be notified when the process has finished.", scalar @files_to_upload)
											. "</span>");	
											$upload_button->set_sensitive(TRUE);													
									}else{
											$u1_hint->set_markup("<span size='small' color='red'>" . 
											sprintf($d->get("Folder %s is not synchronized with Ubuntu One.\nPlease choose an alternative folder.") , "'".$u1_fc->get_current_folder."'") 
											. "</span>");
											$u1_hint2->set_markup("");				
											$upload_button->set_sensitive(FALSE);
									}
								}else{
									$u1_hint->set_markup("");								
									$u1_hint2->set_markup("");						  
									$upload_button->set_sensitive(FALSE);					  
								}
							});

							#change text and status when folder is changes
							#FIXME this is ugly here, because we have nearly the same code here as above
							$u1_fc->signal_connect('current-folder-changed', sub {

								#current status
								my ($is_connected, $is_online, $text) = $u1->get_current_status;
								$u1_status->set_text($text);

								if($is_connected && $is_online){
									#is current folder synced?
									if($u1->is_synced_folder($u1_fc->get_current_folder)){
										$u1_hint->set_markup("<span size='small'>" . 
										sprintf($d->nget("Folder %s is synchronized with Ubuntu One.\nThe selected file will be copied to that folder before being published.", "Folder %s is synchronized with Ubuntu One.\nThe selected files will be copied to that folder before being published.", scalar @files_to_upload) , "'".$u1_fc->get_current_folder."'") 
										. "</span>");								
										$u1_hint2->set_markup("<span size='small'>" . 
										$d->nget("<b>Please note:</b> The selected file will be published in a background process.\nYou will be notified when the process has finished.", "<b>Please note:</b> The selected files will be published in a background process.\nYou will be notified when the process has finished.", scalar @files_to_upload)
										. "</span>");	
										$upload_button->set_sensitive(TRUE);													
									}else{
										$u1_hint->set_markup("<span size='small' color='red'>" . 
										sprintf($d->get("Folder %s is not synchronized with Ubuntu One.\nPlease choose an alternative folder.") , "'".$u1_fc->get_current_folder."'") 
										. "</span>");
										$u1_hint2->set_markup("");				
										$upload_button->set_sensitive(FALSE);
									}
								}else{
										$u1_hint->set_markup("");								
										$u1_hint2->set_markup("");						  
										$upload_button->set_sensitive(FALSE);					  
								}
							});

							#init texts and status - emit first event manually
							$u1_fc->signal_emit('current-folder-changed');

						#not connected   
						}else{
							$u1_hint->set_markup("<span size='small' color='red'>" . $d->get("Ubuntu One service cannot be found.") . "</span>");
							$tooltips->set_tip( $u1_hbox_hint, $con_result );
							$upload_button->set_sensitive(FALSE);
						}

					#wrong api version
					}else{
						$u1_hint->set_markup("<span size='small' color='red'>" . $d->get("/publicfiles is not available. Your Ubuntu One installation seems to be out of date.") . "</span>");
						$upload_button->set_sensitive(FALSE);
						$u1_fc->set_sensitive(FALSE);				
					}

				#ubuntuone enabled?
				}else{
					$u1_status->set_text($d->get("Net::DBus::GLib/libnet-dbus-glib-perl needs to be installed for this feature"));
					$upload_button->set_sensitive(FALSE);
					$u1_fc->set_sensitive(FALSE);
				}
			}  
			
		});

		$hosting_dialog->vbox->add($unotebook);

		my $hosting_progress = Gtk2::ProgressBar->new;
		$hosting_progress->set_no_show_all(TRUE);
		$hosting_progress->set_ellipsize('middle');
		$hosting_progress->set_orientation('left-to-right');
		$hosting_dialog->vbox->add($hosting_progress);

		$hosting_dialog->show_all;
		
		#restore recently used upload tab
		if(defined $sc->get_ruu_tab && $sc->get_ruu_tab){
			$unotebook->set_current_page($sc->get_ruu_tab);
		}
		#and the relevant detail (folder, uploader etc.)
		if(defined $sc->get_ruu_hosting && $sc->get_ruu_hosting){		
			$hosting->set_active($sc->get_ruu_hosting);
		}
		if(defined $sc->get_ruu_places && $shf->folder_exists($sc->get_ruu_places)){
			$places_fc->set_current_folder($sc->get_ruu_places);
		}	
		if(defined $sc->get_ruu_u1 && $shf->folder_exists($sc->get_ruu_u1)){
			$u1_fc->set_current_folder($sc->get_ruu_u1);
		}

		#DIALOG RUN
		while (my $hosting_response = $hosting_dialog->run) {

			#start upload
			if ( $hosting_response eq "accept" ) {

			 #running state of dialog
			 $upload_button->set_sensitive(FALSE);
			 $close_button->set_sensitive(FALSE);
			 $hosting_progress->show;

				#public hosting
				if ( $unotebook->get_current_page == 0 ) {
					my $model            = $hosting->get_model();
					my $hosting_iter     = $hosting->get_active_iter();
					my $hosting_host     = $model->get_value( $hosting_iter, 0 );
					my $hosting_username = $model->get_value( $hosting_iter, 1 );
					my $hosting_password = $model->get_value( $hosting_iter, 2 );
					
					if ( $hosting_host eq "imagebanana.com" ) {
						my $uploader
							= Shutter::Upload::ImageBanana->new( $hosting_host, $sc->get_debug, $shutter_root, $d, $window, SHUTTER_VERSION );
						my $counter = 1;
						$hosting_progress->set_fraction(0);
						foreach my $key (@files_to_upload) {
							
							my $file = $session_screens{$key}->{'long'};
							
							$hosting_progress->set_text($file);

							#update gui
							&fct_update_gui;
							my %upload_response = $uploader->upload( $shf->switch_home_in_file($file), $hosting_username, $hosting_password );

							if ( is_success( $upload_response{'status'} ) ) {
								$uploader->show;
								&fct_show_status_message( 1, $file . " " . $d->get("uploaded") );
							} else {
								my $response = &dlg_upload_error_message( $upload_response{'status'}, $upload_response{'max_filesize'} );

								#10 == skip all, 20 == skip, else == cancel
								last if $response == 10;
								next if $response == 20;
								redo if $response == 30;
								next;
							}
							$hosting_progress->set_fraction( $counter / @files_to_upload );

							#update gui
							&fct_update_gui;
							$counter++;
						}
						$uploader->show_all;
					} elsif ( $hosting_host eq "imageshack.us" ) {
						my $ishack = Shutter::Upload::ImageShack->new();
						
						#clear possible cookie (is this really needed here?)
						$ishack->logout;
											
						#upload
						my $counter = 1;
						$hosting_progress->set_fraction(0);
						foreach my $key (@files_to_upload) {
							
							my $file = $session_screens{$key}->{'long'};

							#login
							eval { $ishack->login($hosting_username, $hosting_password); };
							if ($@) {
								my $response = $sd->dlg_error_message( $d->get("Please check your credentials and try again."),
									$d->get("Login failed!") );

								next;
							}

							$hosting_progress->set_text($file);

							#update gui
							&fct_update_gui;
							my $url = undef;
							eval { $url = $ishack->host( $file, undef ); };
							if ($@) {
								my $response = $sd->dlg_error_message(
									$d->get("Please check your connectivity and try again."),
									$d->get("Connection error!"),
									$d->get("Skip all"), 
									$d->get("Skip"), 
									$d->get("Retry")
								);

								#10 == skip all, 20 == skip, else == cancel
								last if $response == 10;
								next if $response == 20;
								redo if $response == 30;
								next;
							}

							#get short link
							my $short_url = undef;
							eval { $short_url = $ishack->hosted_short; };

							my $thumb_url = undef;
							eval { $thumb_url = $ishack->hosted_thumb; };

							if ($url) {
								$ishack->show( $hosting_host, $hosting_username, $file, $url, $thumb_url, $short_url, RC_OK, $d, $window, $shutter_root );
								&fct_show_status_message( 1, $file . " " . $d->get("uploaded") );
							} else {
								my $response = $sd->dlg_error_message(
									$d->get("Please check your connectivity and try again."),
									$d->get("Connection error!"),
									$d->get("Skip all"), 
									$d->get("Skip"), 
									$d->get("Retry")
								);

								#10 == skip all, 20 == skip, else == cancel
								last if $response == 10;
								next if $response == 20;
								redo if $response == 30;
								next;
							}
							$hosting_progress->set_fraction( $counter / @files_to_upload );

							#update gui
							&fct_update_gui;
							$counter++;
						}
						$ishack->show_all;
					}

					#ftp
				} elsif ( $unotebook->get_current_page == 1 ) {

					#create upload object
					my $uploader = Shutter::Upload::FTP->new( $sc->get_debug, $shutter_root, $d, $window, $ftp_mode_combo_dlg->get_active );

					my $counter = 1;
					my $login   = FALSE;
					$hosting_progress->set_fraction(0);

					#start upload
					foreach my $key (sort @files_to_upload) {

						my $file = $session_screens{$key}->{'long'};

						#need to login?
						my @upload_response;
						unless ($login) {

							eval { $uploader->quit; };

							@upload_response = $uploader->login( $ftp_remote_entry_dlg->get_text, $ftp_username_entry_dlg->get_text,
								$ftp_password_entry_dlg->get_text );

							if ($upload_response[0]) {

								#we already get translated error messaged back
								my $response = $sd->dlg_error_message( 
									$upload_response[1], 
									$upload_response[0],
									undef, undef, undef,
									undef, undef, undef,
									$upload_response[2]
								);
								next;
							} else {
								$login = TRUE;
							}

						}

						$hosting_progress->set_text($file);

						#update gui
						&fct_update_gui;
						@upload_response = $uploader->upload( $shf->switch_home_in_file($file) );
					
						#upload returns FALSE if there is no error
						unless ($upload_response[0]) {
						
							#everything is fine here
							&fct_show_status_message( 1, $file . " " . $d->get("uploaded") );

							#show as notification
							my $notify 	= $sc->get_notification_object;
							$notify->show( $d->get("Successfully uploaded"), sprintf($d->get("The file %s was successfully uploaded."), $file ) );
							
							#copy website url to clipboard
							if($ftp_wurl_entry_dlg->get_text){
								my $wuri = Gnome2::VFS::URI->new ($ftp_wurl_entry_dlg->get_text);
								
								my ( $short, $folder, $ext ) = fileparse( $file, qr/\.[^.]*/ );
								$wuri = $wuri->append_file_name($short.$ext);										
								$clipboard->set_text($wuri->to_string);
								print "copied URI ", $wuri->to_string, " to clipboard\n" if $sc->get_debug;		
							}
						
						} else {

							#we already get translated error messaged back
							my $response = $sd->dlg_error_message( 
								$upload_response[1], 
								$upload_response[0],
								$d->get("Skip all"), 
								$d->get("Skip"),
								$d->get("Retry"),
								undef, undef, undef,
								$upload_response[2]
							);

							#10 == skip all, 20 == skip, 30 == redo, else == cancel
							if ( $response == 10 ) {
								last;
							} elsif ( $response == 20 ) {
								$login = FALSE;
								next;
							} elsif ( $response == 30 ) {
								$login = FALSE;
								redo;
							} else {
								next;
							}

						}
						$hosting_progress->set_fraction( $counter / @files_to_upload );

						#update gui
						&fct_update_gui;
						$counter++;
					} #end foreach
					
					eval { $uploader->quit; };
				
				#xfer using Gnome-VFS - we use this for u1 as well
				} elsif ( $unotebook->get_current_page == 2 || $unotebook->get_current_page == 3) {
			
					my $counter = 1;
					$hosting_progress->set_fraction(0);

					#start upload
					foreach my $key (sort @files_to_upload) {
						
						my $file = $session_screens{$key}->{'long'};
						
						$hosting_progress->set_text($file);
						
						#update gui
						&fct_update_gui;

						my $source_uri = Gnome2::VFS::URI->new ($file);
						
						my $target_uri = undef;
						#places
						if($unotebook->get_current_page == 2){
							$target_uri = Gnome2::VFS::URI->new ($places_fc->get_uri);
						#u1
						}else{
							$target_uri = Gnome2::VFS::URI->new ($u1_fc->get_uri);
						}
													
						$target_uri = $target_uri->append_file_name($source_uri->extract_short_name);

				   #~ print sprintf("%s und %s \n", $target_uri->to_string, $source_uri->to_string);

						my $result;
						unless(Gnome2::VFS->unescape_string($target_uri->to_string) eq Gnome2::VFS->unescape_string($source_uri->to_string)){
							unless($target_uri->exists){
								$result = Gnome2::VFS::Xfer->uri ($source_uri, $target_uri, 'default', 'abort', 'replace', sub{ return TRUE });
							}else{
								$result = 'error-file-exists';	
							}
						}else{
							$result = 'ok';
						}

						#everything is fine here
						if($result eq 'ok'){
							#places
							if($unotebook->get_current_page == 2){
								if($target_uri->is_local){
									&fct_show_status_message( 1, $file . " " . $d->get("exported") );
									#show as notification
									my $notify 	= $sc->get_notification_object;
									$notify->show( $d->get("Successfully exported"), sprintf($d->get("The file %s was successfully exported."), $file ) );
								}else{
									&fct_show_status_message( 1, $file . " " . $d->get("uploaded") );
									#show as notification
									my $notify 	= $sc->get_notification_object;
									$notify->show( $d->get("Successfully uploaded"), sprintf($d->get("The file %s was successfully uploaded."), $file ) );
								}
							#u1 - call publishing API
							}else{
								$session_screens{$key}->{'links'}->{'ubuntu-one'}->{'pubfile'} = Gnome2::VFS->unescape_string($target_uri->get_path);
								&fct_show_status_message( 1, sprintf($d->get("Publishing %s..."), $file) );

								my $u1 = Shutter::Upload::UbuntuOne->new($sc);
								$u1->connect_to_bus;
							   
								if($u1->is_connected){
									my $sd_public = $u1->get_syncdaemon_public;
									my $sd_fs     = $u1->get_syncdaemon_fs;
									my %meta;
									eval{
									   %meta = %{$sd_fs->get_metadata($file)};
									};
									unless($@){
									   #call publishing api directly if the file is already uploaded
									   #if not the file is uploaded first and publishing api is called afterwards (&fct_init_u1_watcher)
									   if(my $key = &fct_get_key_by_pubfile($meta{'path'})){
										  $sd_public->change_public_access($meta{'share_id'}, $meta{'node_id'}, TRUE);
									   }
									}
								}   

							}
						
						}elsif($result eq 'error-file-exists'){

							#ask the user to replace the image
							#replace button
							my $replace_btn = Gtk2::Button->new_with_mnemonic( $d->get("_Replace") );
							$replace_btn->set_image( Gtk2::Image->new_from_stock( 'gtk-save-as', 'button' ) );

							my $target_path=undef;
							if($target_uri->is_local){
								$target_path = $shf->utf8_decode(Gnome2::VFS->unescape_string($target_uri->extract_dirname));
							}else{								
								$target_path = $shf->utf8_decode(Gnome2::VFS->unescape_string($target_uri->get_scheme."://".$target_uri->get_host_name.$target_uri->extract_dirname));
							}

							my $response = $sd->dlg_warning_message(
								sprintf( $d->get("The image already exists in %s. Replacing it will overwrite its contents."), "'" . $target_path ."'"),
								sprintf( $d->get("An image named %s already exists. Do you want to replace it?"), "'" . $target_uri->extract_short_name . "'" ),
								$d->get("Skip all"), $d->get("Skip"),
								undef,
								$replace_btn,
								undef, undef
							);

							#10 == skip all, 20 == skip, 40 == replace, else == cancel
							if ( $response == 10 ) {
								last;
							} elsif ( $response == 20 ) {
								next;
							} elsif ( $response == 40 ) {
								$result = Gnome2::VFS::Xfer->uri ($source_uri, $target_uri, 'default', 'abort', 'replace', sub{ return TRUE });
								
								#check result again
								if($result eq 'ok'){	

									#places
									if($unotebook->get_current_page == 2){
										if($target_uri->is_local){
											&fct_show_status_message( 1, $file . " " . $d->get("exported") );
											#show as notification
											my $notify 	= $sc->get_notification_object;
											$notify->show( $d->get("Successfully exported"), sprintf($d->get("The file %s was successfully exported."), $file ) );                             
										}else{
											&fct_show_status_message( 1, $file . " " . $d->get("uploaded") );
											#show as notification
											my $notify 	= $sc->get_notification_object;
											$notify->show( $d->get("Successfully uploaded"), sprintf($d->get("The file %s was successfully uploaded."), $file ) );                              
										}
									#u1
									}else{
										$session_screens{$key}->{'links'}->{'ubuntu-one'}->{'pubfile'} = Gnome2::VFS->unescape_string($target_uri->get_path);
										&fct_show_status_message( 1, sprintf($d->get("Publishing %s..."), $file) );
									}
			
								} else{

									my $response = &dlg_upload_error_message_gnome_vfs($target_uri, $result);

									#10 == skip all, 20 == skip, 40 == retry, else == cancel
									if ( $response == 10 ) {
										last;
									} elsif ( $response == 20 ) {
										next;
									} elsif ( $response == 40 ) {
										redo;
									} else {
										next;
									}										
									
								}
							}	
							
						}else{

							my $response = &dlg_upload_error_message_gnome_vfs($target_uri, $result);

							#10 == skip all, 20 == skip, 40 == retry, else == cancel
							if ( $response == 10 ) {
								last;
							} elsif ( $response == 20 ) {
								next;
							} elsif ( $response == 40 ) {
								redo;
							} else {
								next;
							}					
			
						}

						$hosting_progress->set_fraction( $counter / @files_to_upload );

						#update gui
						&fct_update_gui;
						$counter++;
														
					}
					
				}

				#save recently used upload tab
				$sc->set_ruu_tab($unotebook->get_current_page);
				#and the relevant detail (folder, uploader etc.)
				#hosting service		
				$sc->set_ruu_hosting($hosting->get_active);
				$sc->set_ruu_places($places_fc->get_current_folder);
				$sc->set_ruu_u1($u1_fc->get_current_folder);
				
				#set initial state of dialog
				$upload_button->set_sensitive(TRUE);
				$close_button->set_sensitive(TRUE);
				$hosting_progress->hide;
			
			#response != accept
			} else {
				$hosting_dialog->destroy();
				return FALSE;
			}   

		}    #dialog loop
	}

	sub dlg_upload_error_message_gnome_vfs {
		my $target_uri = shift;
		my $result = shift;

		my $target_path=undef;
		if($target_uri->is_local){
			$target_path = $shf->utf8_decode(Gnome2::VFS->unescape_string($target_uri->extract_dirname));
		}else{								
			$target_path = $shf->utf8_decode(Gnome2::VFS->unescape_string($target_uri->get_scheme."://".$target_uri->get_host_name.$target_uri->extract_dirname));
		}

		#retry button
		my $retry_btn = Gtk2::Button->new_with_mnemonic( $d->get("_Retry") );
		$retry_btn->set_image( Gtk2::Image->new_from_stock( 'gtk-redo', 'button' ) );

		my $response = $sd->dlg_error_message( 
			sprintf( $d->get(  "Error while copying the image %s."), "'" . $target_uri->extract_short_name . "'"),
			sprintf( $d->get(  "There was an error copying the image into %s."), "'" . $target_path . "'" ),
			$d->get("Skip all"), 
			$d->get("Skip"),
			undef,
			$retry_btn,
			undef,
			undef,
			Gnome2::VFS->result_to_string ($result)
		);
		
		return $response;
		
	}

	sub dlg_upload_error_message {
		my ( $status, $max_filesize ) = @_;

		my $response;
		if ( $status == 999 ) {
			$response = $sd->dlg_error_message( 
			 $d->get("Please check your credentials and try again."), 
			 $d->get("Error while login")
		  );
		} elsif ( $status == 998 ) {
			$response = $sd->dlg_error_message( 
			 $d->get("Maximum filesize reached"),
				$d->get("Error while uploading"), 
			 $d->get("Skip all"), $d->get("Skip"), undef,
			 undef, undef, undef,
			 sprintf($d->get("Maximum filesize: %s"), $max_filesize)
		  );
		} else {
			$response = $sd->dlg_error_message(
				$d->get("Please check your connectivity and try again."),
				$d->get("Error while connecting"),
				$d->get("Skip all"), $d->get("Skip"), $d->get("Retry"),
			 undef, undef, undef,
			 $status
			);
		}
		return $response;
	}

	sub dlg_profile_name {
		my ( $curr_profile_name, $combobox_settings_profiles ) = @_;

		my $profile_dialog = Gtk2::MessageDialog->new( $window, [qw/modal destroy-with-parent/], 'other', 'none', undef );

		$profile_dialog->set_title("Shutter");

		$profile_dialog->set( 'image' => Gtk2::Image->new_from_stock( 'gtk-dialog-question', 'dialog' ) );

		$profile_dialog->set( 'text' => $d->get( "Save current preferences as new profile") );

		$profile_dialog->set( 'secondary-text' => $d->get("New profile name") . ": " );

		$profile_dialog->add_button( 'gtk-cancel', 10 );
		$profile_dialog->add_button( 'gtk-save', 20 );

		$profile_dialog->set_default_response(20);

		my $new_profile_name_vbox = Gtk2::VBox->new();
		my $new_profile_name_hint = Gtk2::Label->new();	
		my $new_profile_name      = Gtk2::Entry->new();
		$new_profile_name->set_activates_default(TRUE);

		#here are all invalid char codes
		my @invalid_codes = (47,92,63,37,42,58,124,34,60,62,44,59,35,38);
		$new_profile_name->signal_connect('key-press-event' => sub {
			my $new_profile_name 	= shift;
			my $event 				= shift;
			
			my $input = Gtk2::Gdk->keyval_to_unicode ($event->keyval); 
			
			#invalid input
			#~ print $input."\n";
			if(grep($input == $_, @invalid_codes)){
				my $char = chr($input);
				$char = '&amp;' if $char eq '&';
				$new_profile_name_hint->set_markup(
				"<span size='small'>" . 
				sprintf($d->get("Reserved character %s is not allowed to be in a filename.") , "'".$char."'") .
				"</span>");	
				return TRUE;
			}else{
				#clear possible message when valid char is entered
				$new_profile_name_hint->set_markup("<span size='small'></span>");						
				return FALSE;
			}
		});

		#show name of current profile
		$new_profile_name->set_text( $curr_profile_name)
			if defined $curr_profile_name;

		$new_profile_name_vbox->pack_start_defaults($new_profile_name);
		$new_profile_name_vbox->pack_start_defaults($new_profile_name_hint);
		$profile_dialog->vbox->add($new_profile_name_vbox);
		$profile_dialog->show_all;

		#run dialog
		my $profile_response = $profile_dialog->run;

		#handle user responses here
		if ( $profile_response == 20 ) {
			my $entered_name = $new_profile_name->get_text;

			if ( $shf->file_exists("$ENV{'HOME'}/.shutter/profiles/$entered_name.xml") ) {

				#ask the user to replace the profile
				#replace button
				my $replace_btn = Gtk2::Button->new_with_mnemonic( $d->get("_Replace") );
				$replace_btn->set_image( Gtk2::Image->new_from_stock( 'gtk-save-as', 'button' ) );

				my $response = $sd->dlg_warning_message(
					$d->get("Replacing it will overwrite its contents."),
					sprintf( $d->get("A profile named %s already exists. Do you want to replace it?"), "'" . $entered_name . "'"),
					undef, undef, undef,
					$replace_btn, undef, undef
				);

				#40 == replace_btn was hit
				if ( $response != 40 ) {
					$profile_dialog->destroy();
					return FALSE;
				}
			}

			$profile_dialog->destroy();
			return $entered_name;
		} else {
			$profile_dialog->destroy();
			return FALSE;
		}
	}

	sub fct_zoom_in {
		my $key = &fct_get_current_file;
		if($key){
			$session_screens{$key}->{'image'}->zoom_in;	
		}
	}

	sub fct_zoom_out {
		my $key = &fct_get_current_file;
		if($key){
			$session_screens{$key}->{'image'}->zoom_out;		
		}	
	}

	sub fct_zoom_100 {
		my $key = &fct_get_current_file;
		if($key){
			$session_screens{$key}->{'image'}->set_zoom(1);			
		}	
	}

	sub fct_zoom_best {
		my $key = &fct_get_current_file;
		if($key){
			$session_screens{$key}->{'image'}->set_fitting(TRUE);			
		}	
	}

	sub fct_fullscreen {
		my ($widget) = @_;
		
		if($widget->get_active){
			$window->fullscreen;			
		}else{
			$window->unfullscreen;	
		}
	}

	sub fct_navigation_toolbar {
		my ($widget) = @_;
		
		if($widget->get_active){
			$nav_toolbar->show;
			foreach($nav_toolbar->get_children){
				$_->show_all;
			}		
		}else{
			$nav_toolbar->hide;
			foreach($nav_toolbar->get_children){
				$_->hide_all;
			}		
		}
	}


}

1;
